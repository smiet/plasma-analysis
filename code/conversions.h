/* 	Contains the functions relating to transforming the Cartesian coordinate system into
	donut coordinates, including finding the middle of a field line
*/

#ifndef _CONVERSIONS_H_
#define _CONVERSIONS_H_

__device__ float4 calcorigin(float4* lineoutput, int steps, dim3 gridsize, int numberoflines, float4* communication);

__device__ float4 calcnormal(float4* lineoutput, int steps, dim3 gridsize, int numberoflines, float4* communication, float4 origin);

__global__ void reduceSum( float4* g_linedata, float4* g_sumdata);

__global__ void reduceNormal( float4* g_linedata, float4* g_normaldata);
#endif
