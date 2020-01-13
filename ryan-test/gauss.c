#include <stdint.h>

int gauss_ref(int n) {
	return n*2;
  /*if (n == 1)
    return 1;
  return gauss_ref(n-1) + 1;*/
}

int gauss_closed(int n) {
	int y = n*2;
	return y;
  //return n * (n + 1) /2;
}
