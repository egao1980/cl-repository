#ifndef CALC_H
#define CALC_H

#define CALC_MAX_VALUE 1000000

typedef struct {
    int a;
    int b;
    int sum;
} calc_result;

calc_result calc_add(int a, int b);
const char *calc_version(void);

#endif /* CALC_H */
