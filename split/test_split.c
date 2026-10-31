// test_split: qe_split's zgemm_/dgemm_ against one cblas call, for every split axis, both
// orientations, alpha and beta, lowercase TRANS and calls left on Accelerate.
//
// usage: test_split [head]   with AB_MODE=cpu (GPU parts run on Accelerate: tests the split's
//        offsets and sums) or AB_MODE=gpu AB_MIN_GPU_DIM=0 (GPU parts on the GPU)
// Error per case: max |C - R| / (|alpha| |op(A)| |op(B)| + |beta| |C0|) over all elements, with R
// from cblas, in u2 = 2^-48; the bound is 64 u2 (the GPU path's double-float products are at a
// few u2; on Accelerate alone the error is far below 1). Exit status: number of failed cases.
#include <complex.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK
#endif
#include <Accelerate/Accelerate.h>

typedef double _Complex zc;
// qe_split's _zgemm_ and _dgemm_, the symbols Fortran calls (Accelerate's headers rename zgemm_ and
// dgemm_ to their new-LAPACK entry points)
void f_zgemm(const char *, const char *, const int *, const int *, const int *, const zc *, const zc *, const int *,
             const zc *, const int *, const zc *, zc *, const int *) __asm__("_zgemm_");
void f_dgemm(const char *, const char *, const int *, const int *, const int *, const double *, const double *,
             const int *, const double *, const int *, const double *, double *, const int *) __asm__("_dgemm_");

static unsigned long long sm = 42;
static double rnd(void) {  // splitmix64 -> [-1, 1)
    unsigned long long z = (sm += 0x9E3779B97F4A7C15ull);
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return (double)(z >> 11) * 0x1p-53 * 2.0 - 1.0;
}

typedef struct { const char *name; int z; char ta, tb; int M, N, K; zc alpha, beta; } Case;
static const Case CASES[] = {
    {"zUN.k1 beta=1", 1, 'N', 'N', 3000, 320, 600, 1, 1},
    {"zUN.k2 beta=0", 1, 'N', 'N', 3000, 288, 800, 1, 0},
    {"zUN lower", 1, 'n', 'n', 2500, 300, 500, 1, 1},
    {"zUM.k0 beta=1", 1, 'N', 'N', 3000, 100, 200, 1, 1},
    {"zUM.k1 alpha,beta", 1, 'N', 'N', 2600, 160, 320, 0.5 - 0.25 * I, -0.75 + 0.125 * I},
    {"zRK.t1 beta=0", 1, 'C', 'N', 300, 400, 3000, 1, 0},
    {"zRK.t0 beta=1", 1, 'C', 'N', 160, 160, 3200, 1, 1},
    {"zRK lower alpha", 1, 'c', 'n', 200, 300, 2600, -1, 0.5},
    {"z pass small", 1, 'N', 'N', 100, 50, 40, 1, 1},
    {"z pass N,C", 1, 'N', 'C', 3000, 300, 600, 1, 0},
    {"dUN.k1", 0, 'N', 'N', 3000, 320, 600, 1, 1},
    {"dUM.k0", 0, 'N', 'N', 3000, 100, 200, 2, 0},
    {"dRK.t1 T", 0, 'T', 'N', 300, 400, 3000, 2, 0},
    {"dRK.t0 C", 0, 'C', 'N', 160, 160, 3200, 1, 1},
};

static void fill(int z, void *X, double *Xa, size_t n) {  // random entries, and their moduli in Xa
    for (size_t i = 0; i < n; i++) {
        if (z) ((zc *)X)[i] = rnd() + rnd() * I; else ((double *)X)[i] = rnd();
        Xa[i] = z ? cabs(((zc *)X)[i]) : fabs(((double *)X)[i]);
    }
}

static int run(const Case *c) {
    int M = c->M, N = c->N, K = c->K, ta = c->ta == 'N' || c->ta == 'n', tb = c->tb == 'N' || c->tb == 'n';
    int lda = (ta ? M : K) + 3, ldb = (tb ? K : N) + 5, ldc = M + 7;
    size_t nA = (size_t)lda * (ta ? K : M), nB = (size_t)ldb * (tb ? N : K), nC = (size_t)ldc * N;
    size_t es = c->z ? sizeof(zc) : sizeof(double);
    void *A = malloc(nA * es), *B = malloc(nB * es), *C = malloc(nC * es), *R = malloc(nC * es), *C0 = malloc(nC * es);
    double *Aa = malloc(nA * 8), *Ba = malloc(nB * 8), *Ca = malloc(nC * 8), *E = calloc(nC, 8);
    fill(c->z, A, Aa, nA);
    fill(c->z, B, Ba, nB);
    fill(c->z, C0, Ca, nC);
    memcpy(C, C0, nC * es);
    memcpy(R, C0, nC * es);
    enum CBLAS_TRANSPOSE TA = ta ? CblasNoTrans : (c->ta == 'T' || c->ta == 't') ? CblasTrans : CblasConjTrans;
    enum CBLAS_TRANSPOSE TB = tb ? CblasNoTrans : (c->tb == 'T' || c->tb == 't') ? CblasTrans : CblasConjTrans;
    double aa, ab;
    if (c->z) {
        f_zgemm(&c->ta, &c->tb, &M, &N, &K, &c->alpha, A, &lda, B, &ldb, &c->beta, C, &ldc);
        cblas_zgemm(CblasColMajor, TA, TB, M, N, K, &c->alpha, A, lda, B, ldb, &c->beta, R, ldc);
        aa = cabs(c->alpha); ab = cabs(c->beta);
    } else {
        double al = creal(c->alpha), be = creal(c->beta);
        f_dgemm(&c->ta, &c->tb, &M, &N, &K, &al, A, &lda, B, &ldb, &be, C, &ldc);
        cblas_dgemm(CblasColMajor, TA, TB, M, N, K, al, A, lda, B, ldb, be, R, ldc);
        aa = fabs(al); ab = fabs(be);
    }
    // the scale |op(A)| |op(B)|, from the moduli
    cblas_dgemm(CblasColMajor, TA == CblasNoTrans ? CblasNoTrans : CblasTrans, TB == CblasNoTrans ? CblasNoTrans : CblasTrans,
                M, N, K, aa, Aa, lda, Ba, ldb, 0, E, ldc);
    double err = 0;
    long diff = 0, pad = 0;
    for (int j = 0; j < N; j++)
        for (int i = 0; i < ldc; i++) {
            size_t k = (size_t)j * ldc + i;
            double d = c->z ? cabs(((zc *)C)[k] - ((zc *)R)[k]) : fabs(((double *)C)[k] - ((double *)R)[k]);
            if (i >= M) { pad += d != 0; continue; }  // padding rows must be untouched
            double s = E[k] + ab * Ca[k];
            if (d != 0) diff++;
            if (s > 0 && d / s > err) err = d / s;
        }
    err /= 0x1p-48;
    int ok = err <= 64 && pad == 0;
    printf("%-20s %c%c M=%d N=%d K=%d  max error %.3f u2  elements differing from cblas %ld of %ld  padding touched %ld  %s\n",
           c->name, c->ta, c->tb, M, N, K, err, diff, (long)M * N, pad, ok ? "ok" : "FAIL");
    free(A); free(B); free(C); free(R); free(C0); free(Aa); free(Ba); free(Ca); free(E);
    return !ok;
}

int main(int argc, char **argv) {
    // small thresholds so that the test shapes split; set before the first call, when they are read
    setenv("QE_SPLIT", "1", 0);
    setenv("QE_SPLIT_DGEMM", "1", 0);
    setenv("QE_SPLIT_MIN_GF", "0.01", 0);
    setenv("QE_SPLIT_REPORT", "1", 0);
    if (argc > 1 && !strcmp(argv[1], "head")) setenv("QE_SPLIT_GPU", "head", 1);
    int fails = 0;
    for (size_t i = 0; i < sizeof CASES / sizeof CASES[0]; i++) fails += run(&CASES[i]);
    printf("%d of %zu cases failed\n", fails, sizeof CASES / sizeof CASES[0]);
    return fails;
}
