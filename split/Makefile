# qe_split.o, the object linked into pw.x, and its test.
#   AB_INC  directory holding apple_bottom.h, from the same commit as the library
#   AB_LIB  directory holding the libapplebottom.dylib the test links and loads
#   OUT     where the object and the test go (default: this directory)
# Apple clang, not gcc: Accelerate's and libdispatch's headers use clang extensions.
SPLIT_CC ?= /usr/bin/clang
CFLAGS   ?= -O2 -std=gnu11 -Wall -Wextra
OUT      ?= .
AB_INC   ?= $(error set AB_INC to the directory holding apple_bottom.h)
AB_LIB   ?= $(error set AB_LIB to the directory holding libapplebottom.dylib)

all: $(OUT)/qe_split.o

$(OUT)/qe_split.o: qe_split.c
	$(SPLIT_CC) $(CFLAGS) -I$(AB_INC) -c $< -o $@

$(OUT)/test_split: test_split.c $(OUT)/qe_split.o
	$(SPLIT_CC) $(CFLAGS) $^ -L$(AB_LIB) -Wl,-rpath,$(AB_LIB) -lapplebottom -o $@

test: $(OUT)/test_split
	AB_MODE=cpu $(OUT)/test_split
	AB_MODE=cpu $(OUT)/test_split head

.PHONY: all test
