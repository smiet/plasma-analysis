#include <iostream>
#include <stdlib.h>

using namespace std;


const int N = 256;

struct vec {
	float x, y, z;
};

void datagen (vec*** data) {
	float spacing = 0.0245436930189;
	float origin = -3.12932085991;
	for (int i=0; i < N; i++) {
		for (int j = 0; j < N; j++) {
			for (int k = 0; k < N; k++) {
				(data[i][j][k]).x = origin + spacing*j;
				(data[i][j][k]).y = - (origin + spacing*i);
				(data[i][j][k]).z = 0;
			}
		}
	}
}

int main () {
	vec*** data; 
	data = (vec***) malloc(N*sizeof(vec**));
	data[0] = (vec**) malloc(N*N*sizeof(vec*));
	data[0][0] = (vec*) malloc(N*N*N*sizeof(vec));
	for (int i=1; i < N; i++) {
		data[i] = (data[0] + i*N);
	}
	for (int i=0; i < N; i++) {
		for (int j=0; j < N; j++) {
			data[i][j] = (data[0][0] + (i*N*N + j*N));
		}
	}
	datagen(data);
	free(data[0][0]);
	free(data[0]);
	free(data);
	return 0;
}
