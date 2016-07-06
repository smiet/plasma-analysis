/* 	Contains the functions relating to transforming the Cartesian coordinate system into
	donut coordinates, including finding the middle of a field line
*/

#ifndef _CONVERSIONS_H_
#define _CONVERSIONS_H_
__device__ int signdiff(float a, float b);
__global__ void reducePC(float4* g_linedata, float4* g_PCdata);
	
__device__ float4 calcorigin(float4* lineoutput, int steps, dim3 gridsize, int numberoflines, float4* communication);

__device__ float4 calcnormal(float4* lineoutput, int steps, dim3 gridsize, int numberoflines, float4* communication, float4 origin);

__global__ void reduceSum( float4* g_linedata, float4* g_sumdata);

__global__ void reduceNormal( float4* g_linedata, float4* g_normaldata);

__device__ float Lengthstep( float4 loc, double dt);

__global__ void lineLength(float4* g_linedata, double dt, float4* g_lengthoutput);
#endif
