CC ?= cc
CFLAGS ?= -O2 -fPIC -Wall

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  LIB = libcalc.dylib
  LDFLAGS = -dynamiclib -install_name @rpath/libcalc.dylib
else ifeq ($(UNAME_S),Linux)
  LIB = libcalc.so
  LDFLAGS = -shared
else
  LIB = libcalc.so
  LDFLAGS = -shared
endif

all: $(LIB)

$(LIB): calc.o
	$(CC) $(LDFLAGS) -o $@ $<

calc.o: calc.c calc.h
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f calc.o $(LIB)

.PHONY: all clean
