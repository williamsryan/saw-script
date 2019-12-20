#include <stdint.h>

int gauss_ref(int n) {
  if (n == 1)
    return 1;
  return gauss_ref(n-1) + 1;
}

int gauss_closed(int n) {
  return n * (n + 1) /2;
}
