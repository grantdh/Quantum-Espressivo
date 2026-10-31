// qe_split.c: dgemm_ and zgemm_ for Quantum ESPRESSO's pw.x that split large GEMMs between
// Accelerate (the CPU's matrix units) and apple-bottom's GPU path. A prototype: results and how
// to build and run it are in split/README.md. The split itself follows apple-bottom's
// benchmarks/bench_split.c.
//
// Linked into pw.x as an object file, so QE's ZGEMM and DGEMM calls bind to these definitions and
// not to a library's. Every call runs on Accelerate (cblas, on the calling thread) unless
// QE_SPLIT=1 and the call falls in a shape class whose GPU share f is above 0:
//   U  'N','N' with M >= QE_SPLIT_MIN_M: Davidson updates, s_psi and add_vuspsi (M = npw).
//      UN splits the columns of C when N >= QE_SPLIT_UN_MIN_N, UM its rows otherwise.
//   R  'C','N' (or 'T','N' for DGEMM) with K >= QE_SPLIT_MIN_K: Davidson overlaps and calbec
//      (K = npw). RK splits the sum: the GPU's partial product goes to a scratch array, which is
//      added to C after both parts finish, C = fl(C_cpu + P_gpu).
// and does at least QE_SPLIT_MIN_GF GFLOP (8MNK for ZGEMM, 2MNK for DGEMM). The CPU part runs on
// the calling thread with cblas_[dz]gemm. The GPU part runs at the same time on a worker thread
// with ab_[dz]gemm_blas, apple-bottom's public BLAS entry points; run with AB_MODE=gpu and
// AB_MIN_GPU_DIM=0, or the library's own routing may send the GPU part to Accelerate.
// A class's name adds the routine and a size bucket, e.g. zUN.k2:
//   U by K: k0 K < 256, k1 256 <= K < 768, k2 K >= 768;  R by M*N: t0 < 2^16, t1 < 2^18, t2 >= 2^18.
// The GPU part is the last columns (UN), rows (UM) or K indices (RK), cut to a multiple of 32
// (UN, UM) or 64 (RK), and at least one multiple from either end.
//
// Environment, read once:
//   QE_SPLIT=1            split (default 0: every call on Accelerate, timed and counted)
//   QE_SPLIT_F=list       GPU shares, e.g. "zUN=0.5,zRK.t2=0.55": a class takes its own entry, else
//                         its axis class's (zUN), else the built-in default (F_DEFAULT below);
//                         0 keeps the class on Accelerate
//   QE_SPLIT_MIN_GF=0.5   QE_SPLIT_MIN_M=2048   QE_SPLIT_MIN_K=2048   QE_SPLIT_UN_MIN_N=256
//   QE_SPLIT_DGEMM=1      also split DGEMMs (default 0)
//   QE_SPLIT_GPU=head     the GPU takes the first columns, rows or K indices instead of the last
//   QE_SPLIT_LOG=path     one line per split call, appended to path.<pid> (QE_SPLIT_LOG_ALL=1:
//                         every call); gseq numbers the GPU parts of the process from 1, which is
//                         AB_TRACE's seq when nothing else in the process calls the library's
//                         BLAS entry points
//   QE_SPLIT_REPORT=1     a summary per class on stderr at exit, lines "QE_SPLIT[pid] ..."
// One split at a time per process: a call made while another thread is splitting runs on
// Accelerate.
#include <ctype.h>
#include <dispatch/dispatch.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#ifndef ACCELERATE_NEW_LAPACK
#define ACCELERATE_NEW_LAPACK  // the cblas entry points apple-bottom's own CPU path calls
#endif
#include <Accelerate/Accelerate.h>
#include "apple_bottom.h"

typedef double _Complex zc;

enum { AX_N, AX_M, AX_K, NAX };
#define NBK 3
#define NCLS (2 * NAX * NBK)   // routine (z, d) x axis x size bucket
static const char *AX_NAME[NAX] = {"UN", "UM", "RK"};
static const int AX_ALIGN[NAX] = {32, 32, 64};
// Starting shares, the best ones of the GEMM-level split on QE's shapes (apple-bottom's
// benchmarks/results/2026-10-28-415cb5d-hybrid-split): U-N 0.51, U-M 0.50, R-K 0.55.
static const double F_DEFAULT[2][NAX] = {{0.51, 0.50, 0.55}, {0.55, 0.50, 0.55}};

static struct {
    bool split, dgemm, head, log_all, report;
    double min_gf, f[NCLS];
    int min_m, min_k, un_min_n;
    const char *log_path, *f_spec;
} cfg;

typedef struct {                    // named after the report's keys; times in ns
    long calls, split, gpu_on_cpu;  // gpu_on_cpu: GPU parts that Accelerate computed
    double gf, gf_split, gf_gpu;
    uint64_t wall, split_wall, cpu, gpu, wait, kadd;  // cpu, gpu: the parts; wait: for the GPU part
} Stat;
static Stat st[NCLS], pass_st[2];
static pthread_mutex_t st_lock = PTHREAD_MUTEX_INITIALIZER;

static inline uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }  // AB_TRACE's clock
static int cls_index(bool z, int ax, int bk) { return (z ? 0 : 1) * NAX * NBK + ax * NBK + bk; }
static void cls_name(int c, char *s, size_t n) {
    int ax = c / NBK % NAX;
    snprintf(s, n, "%c%s.%c%d", c < NAX * NBK ? 'z' : 'd', AX_NAME[ax], ax == AX_K ? 't' : 'k', c % NBK);
}
static double envd(const char *k, double d) { const char *v = getenv(k); return v && *v ? atof(v) : d; }
static bool envb(const char *k) { const char *v = getenv(k); return v && *v && strcmp(v, "0"); }

// QE_SPLIT_F: name=share entries separated by commas or spaces. A full name (zUN.k2) takes
// precedence over its axis class (zUN), which takes precedence over F_DEFAULT.
static void parse_shares(void) {
    int prio[NCLS] = {0};
    for (int c = 0; c < NCLS; c++) cfg.f[c] = F_DEFAULT[c >= NAX * NBK][c / NBK % NAX];
    const char *spec = getenv("QE_SPLIT_F");
    if (!spec) return;
    cfg.f_spec = spec;
    char *s = strdup(spec), *save = NULL;
    for (char *t = strtok_r(s, ", ", &save); t; t = strtok_r(NULL, ", ", &save)) {
        char *eq = strchr(t, '=');
        if (!eq) { fprintf(stderr, "qe_split: QE_SPLIT_F: no '=' in %s\n", t); continue; }
        *eq = 0;
        int p = strchr(t, '.') ? 2 : 1;
        size_t lt = strlen(t);
        bool hit = false;
        for (int c = 0; c < NCLS; c++) {
            char nm[16];
            cls_name(c, nm, sizeof nm);
            if ((p == 2 ? !strcmp(nm, t) : !strncmp(nm, t, lt) && nm[lt] == '.') && p >= prio[c]) {
                cfg.f[c] = atof(eq + 1);
                prio[c] = p;
                hit = true;
            }
        }
        if (!hit) fprintf(stderr, "qe_split: QE_SPLIT_F: no class %s\n", t);
    }
    free(s);
}

// ---------------------------------------------------------------- the split
typedef struct {
    bool z; char ta, tb; int M, N, K, lda, ldb, ldc;
    const void *alpha, *beta, *A, *B; void *C;
    int ax, g, lo;          // the GPU part is [lo, lo + g) of the axis, the CPU part the rest
    void *P;                // RK: the GPU's partial product, M x N, leading dimension M
} Job;

static Job job;             // the split in progress (one per process)
static dispatch_semaphore_t sem_go, sem_done;
static uint64_t g_t0, g_t1;
static bool g_on_gpu;
static long gseq;
static pthread_mutex_t eng = PTHREAD_MUTEX_INITIALIZER;
static void *pbuf;
static size_t pbuf_bytes;

// TRANS as apple-bottom reads it (reference BLAS: 'C' is a plain transpose for real types; any
// other character is out of range, so cblas rejects the call as xerbla would). Upper case here.
static enum CBLAS_TRANSPOSE cblas_trans(char t, bool z) {
    return t == 'N' ? CblasNoTrans : t == 'T' ? CblasTrans : t == 'C' ? (z ? CblasConjTrans : CblasTrans)
                                                                      : (enum CBLAS_TRANSPOSE)0;
}

// [lo, lo + n) of the split axis into C; on the GPU (gpu) or Accelerate. RK's GPU part goes into P
// with beta 0. A whole call is part(j, 0, its axis length, false) (lo = 0: no offsets). Split
// classes have tb = 'N', and op(A) = A for U, A^H or A^T for R, so the offsets index rows.
static void part(const Job *j, int lo, int n, bool gpu) {
    size_t es = j->z ? sizeof(zc) : sizeof(double);
    const char *A = j->A, *B = j->B;
    char *C = j->C;
    int m = j->M, nn = j->N, k = j->K, ldc = j->ldc;
    if (j->ax == AX_N) { B += (size_t)lo * j->ldb * es; C += (size_t)lo * ldc * es; nn = n; }
    else if (j->ax == AX_M) { A += lo * es; C += lo * es; m = n; }
    else { A += lo * es; B += lo * es; k = n; }
    bool to_p = gpu && j->ax == AX_K;
    if (to_p) { C = j->P; ldc = j->M; }
    if (j->z) {
        const zc zero = 0, *beta = to_p ? &zero : j->beta;
        if (gpu)
            ab_zgemm_blas(j->ta, j->tb, m, nn, k, *(const zc *)j->alpha, (const zc *)A, j->lda, (const zc *)B, j->ldb,
                          *beta, (zc *)C, ldc);
        else
            cblas_zgemm(CblasColMajor, cblas_trans(j->ta, true), cblas_trans(j->tb, true), m, nn, k, j->alpha,
                        (const zc *)A, j->lda, (const zc *)B, j->ldb, beta, (zc *)C, ldc);
    } else {
        double alpha = *(const double *)j->alpha, beta = to_p ? 0 : *(const double *)j->beta;
        if (gpu)
            ab_dgemm_blas(j->ta, j->tb, m, nn, k, alpha, (const double *)A, j->lda, (const double *)B, j->ldb, beta,
                          (double *)C, ldc);
        else
            cblas_dgemm(CblasColMajor, cblas_trans(j->ta, false), cblas_trans(j->tb, false), m, nn, k, alpha,
                        (const double *)A, j->lda, (const double *)B, j->ldb, beta, (double *)C, ldc);
    }
}

static void *worker(void *arg) {
    (void)arg;
    for (;;) {
        dispatch_semaphore_wait(sem_go, DISPATCH_TIME_FOREVER);
        g_t0 = now_ns();
        part(&job, job.lo, job.g, true);
        g_t1 = now_ns();
        g_on_gpu = !strcmp(ab_get_last_dispatch_path(), "gpu");  // this thread's last call
        dispatch_semaphore_signal(sem_done);
    }
    return NULL;
}

static void kadd(const Job *j) {  // RK: C += P, over the doubles of each column
    int w = j->z ? 2 : 1;
    double *C = j->C;
    const double *P = j->P;
    for (int c = 0; c < j->N; c++)
        for (int i = 0; i < w * j->M; i++) C[(size_t)c * w * j->ldc + i] += P[(size_t)c * w * j->M + i];
}

// The call's class, -1 for none, and through *ax its split axis.
static int classify(bool z, char ta, char tb, int M, int N, int K, int *ax) {
    if (ta == 'N' && tb == 'N' && M >= cfg.min_m) {
        *ax = N >= cfg.un_min_n ? AX_N : AX_M;
        return cls_index(z, *ax, K < 256 ? 0 : K < 768 ? 1 : 2);
    }
    if ((ta == 'C' || (!z && ta == 'T')) && tb == 'N' && K >= cfg.min_k) {
        long mn = (long)M * N;
        *ax = AX_K;
        return cls_index(z, AX_K, mn < 65536 ? 0 : mn < 262144 ? 1 : 2);
    }
    return -1;
}

// ---------------------------------------------------------------- configuration, log, report
static void cfg_line(FILE *f, const char *pre) {
    const char *rk = getenv("OMPI_COMM_WORLD_RANK");
    fprintf(f, "%s qe_split pid=%d rank=%s build=\"%s\" split=%d dgemm=%d gpu=%s min_gf=%g min_m=%d min_k=%d un_min_n=%d f=\"%s\"\n",
            pre, (int)getpid(), rk ? rk : "-1", ab_build_info(), cfg.split, cfg.dgemm, cfg.head ? "head" : "tail",
            cfg.min_gf, cfg.min_m, cfg.min_k, cfg.un_min_n, cfg.f_spec ? cfg.f_spec : "");
}

static FILE *logf_;
static void close_log(void) { if (logf_) fclose(logf_); logf_ = NULL; }
static void open_log(void) {
    char p[1024];
    snprintf(p, sizeof p, "%s.%d", cfg.log_path, (int)getpid());
    if (!(logf_ = fopen(p, "a"))) { fprintf(stderr, "qe_split: cannot open %s\n", p); return; }
    setvbuf(logf_, NULL, _IOFBF, 1 << 16);
    cfg_line(logf_, "#");
    fprintf(logf_, "# fields: seq t0_ns t1_ns r ta tb M N K cls, and for a split call ax g gseq gM gN gK"
                   " tc_ns tg_ns tw_ns tk_ns path (where the library computed the GPU part)\n");
    atexit(close_log);
}
static pthread_once_t log_once = PTHREAD_ONCE_INIT;

static void report(void) {
    char pre[32];
    snprintf(pre, sizeof pre, "QE_SPLIT[%d]", (int)getpid());
    pthread_mutex_lock(&st_lock);
    cfg_line(stderr, pre);
    for (int c = 0; c < NCLS; c++) {
        const Stat *s = &st[c];
        if (!s->calls) continue;
        char nm[16];
        cls_name(c, nm, sizeof nm);
        double tc = s->cpu * 1e-9, tg = s->gpu * 1e-9;
        double rc = tc > 0 ? (s->gf_split - s->gf_gpu) / tc : NAN, rg = tg > 0 ? s->gf_gpu / tg : NAN;
        fprintf(stderr, "%s %s f=%.3f calls=%ld split=%ld gpu_on_cpu=%ld gf=%.2f gf_split=%.2f gf_gpu=%.2f wall_s=%.4f"
                        " split_wall_s=%.4f cpu_s=%.4f gpu_s=%.4f wait_s=%.4f kadd_s=%.4f r_cpu=%.1f r_gpu=%.1f f_bal=%.3f\n",
                pre, nm, cfg.f[c], s->calls, s->split, s->gpu_on_cpu, s->gf, s->gf_split, s->gf_gpu, s->wall * 1e-9,
                s->split_wall * 1e-9, tc, tg, s->wait * 1e-9, s->kadd * 1e-9, rc, rg, rc + rg > 0 ? rg / (rc + rg) : NAN);
    }
    for (int r = 0; r < 2; r++)
        if (pass_st[r].calls)
            fprintf(stderr, "%s %cpass calls=%ld gf=%.2f wall_s=%.4f\n", pre, r ? 'd' : 'z', pass_st[r].calls,
                    pass_st[r].gf, pass_st[r].wall * 1e-9);
    pthread_mutex_unlock(&st_lock);
}

static void init_cfg(void) {
    cfg.split = envb("QE_SPLIT");
    cfg.dgemm = envb("QE_SPLIT_DGEMM");
    const char *g = getenv("QE_SPLIT_GPU");
    cfg.head = g && !strcmp(g, "head");
    cfg.min_gf = envd("QE_SPLIT_MIN_GF", 0.5);
    cfg.min_m = (int)envd("QE_SPLIT_MIN_M", 2048);
    cfg.min_k = (int)envd("QE_SPLIT_MIN_K", 2048);
    cfg.un_min_n = (int)envd("QE_SPLIT_UN_MIN_N", 256);
    cfg.log_path = getenv("QE_SPLIT_LOG");
    cfg.log_all = envb("QE_SPLIT_LOG_ALL");
    cfg.report = envb("QE_SPLIT_REPORT");
    parse_shares();
    if (cfg.split) {
        const char *mode = getenv("AB_MODE");
        if (!mode || strcmp(mode, "gpu"))
            fprintf(stderr, "qe_split: QE_SPLIT=1 without AB_MODE=gpu: the library may run GPU parts on Accelerate\n");
        sem_go = dispatch_semaphore_create(0);
        sem_done = dispatch_semaphore_create(0);
        pthread_t t;
        if (pthread_create(&t, NULL, worker, NULL)) {
            fprintf(stderr, "qe_split: no worker thread; every call runs on Accelerate\n");
            cfg.split = false;
        } else {
            pthread_detach(t);
        }
    }
    if (cfg.report) atexit(report);
}
static pthread_once_t cfg_once = PTHREAD_ONCE_INIT;

// ---------------------------------------------------------------- one call
static long call_seq;

static void gemm(bool z, char ta, char tb, int M, int N, int K, const void *alpha, const void *A, int lda,
                 const void *B, int ldb, const void *beta, void *C, int ldc) {
    pthread_once(&cfg_once, init_cfg);
    ta = (char)toupper((unsigned char)ta);
    tb = (char)toupper((unsigned char)tb);
    Job j = {z, ta, tb, M, N, K, lda, ldb, ldc, alpha, beta, A, B, C, AX_N, 0, 0, NULL};
    int c = classify(z, ta, tb, M, N, K, &j.ax);
    double gf = (z ? 8.0 : 2.0) * M * N * K * 1e-9;
    bool alpha_nz = z ? *(const zc *)alpha != 0 : *(const double *)alpha != 0;
    int L = j.ax == AX_N ? N : j.ax == AX_M ? M : K, a = AX_ALIGN[j.ax];
    bool split = cfg.split && c >= 0 && (z || cfg.dgemm) && cfg.f[c] > 0 && gf >= cfg.min_gf && alpha_nz && L >= 2 * a;
    if (split) {  // the GPU part: a multiple of the alignment, at least one from either end
        int g = (int)lround(cfg.f[c] * L / a) * a;
        j.g = g < a ? a : g > L - a ? L - a : g;
        j.lo = cfg.head ? 0 : L - j.g;
        split = !pthread_mutex_trylock(&eng);
    }
    if (split && j.ax == AX_K) {
        size_t need = (size_t)M * N * (z ? sizeof(zc) : sizeof(double));
        if (need > pbuf_bytes) {
            free(pbuf);
            pbuf = malloc(need);
            pbuf_bytes = pbuf ? need : 0;
        }
        j.P = pbuf;
        if (!pbuf) { pthread_mutex_unlock(&eng); split = false; }
    }
    long seq = __atomic_add_fetch(&call_seq, 1, __ATOMIC_RELAXED), gs = 0;
    uint64_t t0 = now_ns(), tc = 0, tg = 0, tw = 0, tk = 0, t1;
    bool on_gpu = false;
    if (split) {
        job = j;
        gs = ++gseq;
        dispatch_semaphore_signal(sem_go);
        uint64_t c0 = now_ns();
        part(&j, cfg.head ? j.g : 0, L - j.g, false);
        uint64_t c1 = now_ns();
        dispatch_semaphore_wait(sem_done, DISPATCH_TIME_FOREVER);
        uint64_t jn = now_ns();
        if (j.ax == AX_K) kadd(&j);
        t1 = now_ns();
        tc = c1 - c0; tg = g_t1 - g_t0; tw = jn - c1; tk = t1 - jn; on_gpu = g_on_gpu;
        pthread_mutex_unlock(&eng);
    } else {
        part(&j, 0, L, false);  // the whole call (lo = 0: no offsets)
        t1 = now_ns();
    }
    pthread_mutex_lock(&st_lock);
    Stat *s = c >= 0 ? &st[c] : &pass_st[z ? 0 : 1];
    s->calls++; s->gf += gf; s->wall += t1 - t0;
    if (split) {
        s->split++; s->gf_split += gf; s->gf_gpu += gf * j.g / L; s->gpu_on_cpu += !on_gpu;
        s->split_wall += t1 - t0; s->cpu += tc; s->gpu += tg; s->wait += tw; s->kadd += tk;
    }
    if (cfg.log_path && (split || cfg.log_all)) {
        pthread_once(&log_once, open_log);
        if (logf_) {
            char nm[16] = "pass";
            if (c >= 0) cls_name(c, nm, sizeof nm);
            fprintf(logf_, "seq=%ld t0_ns=%llu t1_ns=%llu r=%c ta=%c tb=%c M=%d N=%d K=%d cls=%s", seq,
                    (unsigned long long)t0, (unsigned long long)t1, z ? 'z' : 'd', ta, tb, M, N, K, nm);
            if (split)
                fprintf(logf_, " ax=%c g=%d gseq=%ld gM=%d gN=%d gK=%d tc_ns=%llu tg_ns=%llu tw_ns=%llu tk_ns=%llu path=%s",
                        "NMK"[j.ax], j.g, gs, j.ax == AX_M ? j.g : M, j.ax == AX_N ? j.g : N, j.ax == AX_K ? j.g : K,
                        (unsigned long long)tc, (unsigned long long)tg, (unsigned long long)tw, (unsigned long long)tk,
                        on_gpu ? "gpu" : "cpu");
            fputc('\n', logf_);
        }
    }
    pthread_mutex_unlock(&st_lock);
}

// ---------------------------------------------------------------- the Fortran BLAS ABI
// Named through asm labels: Accelerate's new-LAPACK headers declare zgemm_ and dgemm_ with the
// assembly names zgemm$NEWLAPACK and dgemm$NEWLAPACK, so a C definition of zgemm_ here would not
// define the _zgemm_ that QE's objects call.
void qe_split_zgemm(const char *ta, const char *tb, const int *m, const int *n, const int *k, const zc *alpha,
                    const zc *a, const int *lda, const zc *b, const int *ldb, const zc *beta, zc *c,
                    const int *ldc) __asm__("_zgemm_");
void qe_split_dgemm(const char *ta, const char *tb, const int *m, const int *n, const int *k, const double *alpha,
                    const double *a, const int *lda, const double *b, const int *ldb, const double *beta,
                    double *c, const int *ldc) __asm__("_dgemm_");

void qe_split_zgemm(const char *ta, const char *tb, const int *m, const int *n, const int *k, const zc *alpha,
                    const zc *a, const int *lda, const zc *b, const int *ldb, const zc *beta, zc *c,
                    const int *ldc) {
    gemm(true, *ta, *tb, *m, *n, *k, alpha, a, *lda, b, *ldb, beta, c, *ldc);
}

void qe_split_dgemm(const char *ta, const char *tb, const int *m, const int *n, const int *k, const double *alpha,
                    const double *a, const int *lda, const double *b, const int *ldb, const double *beta,
                    double *c, const int *ldc) {
    gemm(false, *ta, *tb, *m, *n, *k, alpha, a, *lda, b, *ldb, beta, c, *ldc);
}
