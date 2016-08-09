#include <stdio.h>
#include <helper_cuda.h>
#include <iostream>
#include "constants.cuh"
#include "coordfunctions.cuh"
#include "conversions.cuh"
#include "integration.cuh"
#include "vtkio.cuh"
#include "helper_math.h"

//'Global' texture, declared as an external texture in integration.cu. Stores data on the device.
texture <float4, cudaTextureType3D, cudaReadModeElementType> dataTex;

/*	Generates a circular vectorfield around the origin for testing purposes.
	Note the order of the indices - the first index corresponds to the z coordinate,
	the middle to y and the last to x.
*/
void datagen (float4*** data) {
	//data[z][y][x]
	for (int i=0; i < N; i++) {
		for (int j = 0; j < N; j++) {
			for (int k = 0; k < N; k++) {
				(data[i][j][k]).x = - (origin + spacing*j);
				(data[i][j][k]).y = (origin + spacing*k);
				(data[i][j][k]).z = 0;
				(data[i][j][k]).w = 0;
			}
		}
	}
}

void allocarray (float4*** &hostvfield) {
	hostvfield = (float4***) malloc(N*sizeof(float4**));
	hostvfield[0] = (float4**) malloc(N*N*sizeof(float4*));
	hostvfield[0][0] = (float4*) malloc(N*N*N*sizeof(float4));
	for (int i=1; i < N; i++) {
		hostvfield[i] = (hostvfield[0] + i*N);
	}
	for (int i=0; i < N; i++) {
		for (int j=0; j < N; j++) {
			hostvfield[i][j] = (hostvfield[0][0] + (i*N*N + j*N));
		}
	}
}

void dataprint (float* data, dim3 Size) {
	for(unsigned int i=0; i< Size.x; i++) {
		for(unsigned int j=0; j< Size.y; j++) {
			std::cout << data[Size.y*i+j] << " , ";
		}
		std::cout << std::endl;
	}
}



int main(int argc, char *argv[]) {

	//Check if the input is sensible

	if (argc == 1) {
		std::cout << "Please specify as an argument the path to the .vtk file to use"  << std::endl;
		return 1;
	}
	//Allocate data array on host
	float4*** hostvfield;
	allocarray(hostvfield);

	//Read data from file specified as argument
	float4 dataorigin = {0,0,0,0};
	vtkDataRead(hostvfield[0][0],argv[1], dataorigin);
	if(dataorigin.x != origin || dataorigin.y != origin || dataorigin.z != origin) {
		std::cout << "Warning: origin read from file not equal to origin from constants.h" << std::endl;
	}

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Allocate array on device
	cudaArray* dataArray;
	cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc(32,32,32,32,cudaChannelFormatKindFloat);
	cudaExtent extent = make_cudaExtent(N, N, N);
	checkCudaErrors(cudaMalloc3DArray(&dataArray, &channelDesc,extent));

	//Set linear interpolation mode
	dataTex.filterMode = cudaFilterModeLinear;
	dataTex.addressMode[0] = cudaAddressModeBorder;
	dataTex.addressMode[1] = cudaAddressModeBorder;
	dataTex.addressMode[2] = cudaAddressModeBorder;

	//Copy data (originally from the vtk) to device
	cudaMemcpy3DParms copyParms = {0};
	copyParms.srcPtr = make_cudaPitchedPtr((void *)hostvfield[0][0], extent.width*sizeof(float4), extent.height, extent.depth);
	copyParms.dstArray = dataArray;
	copyParms.extent = extent;
	copyParms.kind = cudaMemcpyHostToDevice;
	checkCudaErrors(cudaMemcpy3D(&copyParms));

	//Copy our texture properties (linear interpolation, texture access) to data array on device
	checkCudaErrors(cudaBindTextureToArray(dataTex, dataArray, channelDesc));

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Declare pointers to arrays with line data (output of integration), one each on device and host
	float4 *d_lines, *h_lines;

	//Set integration parameters (end time, number of steps, etc.)
	const int blockSize = 1024;
	unsigned int steps = 32*blockSize;
	float dt = 1/8.0;

	dim3 gridSizeRK4(1,1);
	dim3 blockSizeRK4(8,8);
	int dataCount = gridSizeRK4.x*gridSizeRK4.y*blockSizeRK4.x*blockSizeRK4.y*steps;
	float4 startloc = make_float4(-1.25,0,-0.25,0); //Location (in Smietcoords) to start the integration, to be varied
	float4 xvec = {0.5,0,0,0};
	float4 yvec = {0,0,0.5,0};

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Allocate space on device to store integration output
	checkCudaErrors(cudaMalloc(&d_lines, dataCount*sizeof(float4)));

	//Allocate space on host to store integration output
	h_lines = (float4*) malloc(dataCount*sizeof(float4));

	//Integrate the vector field
	RK4line<<<gridSizeRK4,blockSizeRK4>>>(d_lines, dt, steps, startloc, xvec, yvec);

	//Copy data from device to host
	checkCudaErrors(cudaMemcpy(h_lines, d_lines, dataCount*sizeof(float4), cudaMemcpyDeviceToHost));

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Allocate space to store origin data

	float4 *d_origins, *h_origins;
	checkCudaErrors(cudaMalloc(&d_origins, dataCount/(2*blockSize)*sizeof(float4)));
	h_origins = (float4*) malloc((dataCount/steps) * sizeof(float4));

	//Add the coordinates of the streamlines coordinatewise (in order to calculate mean).
	reduceSum<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float4)>>>(d_lines, d_origins);
	reduceSum<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float4)>>>(d_origins, d_origins);

	//Copy origin data from device to host
	checkCudaErrors(cudaMemcpy(h_origins, d_origins, (dataCount/steps)*sizeof(float4), cudaMemcpyDeviceToHost));

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Allocating the array to store the length data, both for host and device
	float *d_lengths, *h_lengths;
	checkCudaErrors(cudaMalloc(&d_lengths, dataCount*sizeof(float)));
	h_lengths = (float*) malloc((dataCount/steps)*sizeof(float));

	//Compute the length of each line (locally)
	lineLength<<<dataCount/blockSize,blockSize>>>(d_lines, dt, d_lengths);

	//Add the length of the pieces of the lines to obtain line length
	//Stores the length of the i'th line in d_lengths[i]
	reduceSum<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float)>>>(d_lengths,d_lengths);
	reduceSum<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float)>>>(d_lengths,d_lengths);

	//Copy lengths from device to host
	checkCudaErrors(cudaMemcpy(h_lengths, d_lengths, (dataCount/steps)*sizeof(float), cudaMemcpyDeviceToHost));

	cudaFree(d_lengths);

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Allocating the array to store the radius data, both for host and device
	float *d_radii, *h_radii;
	checkCudaErrors(cudaMalloc(&d_radii, dataCount*sizeof(float)));
	h_radii = (float*) malloc((dataCount/steps)*sizeof(float));


	//Compute the distance from the origin in the xy plane of each point
	rxy<<<dataCount/blockSize,blockSize>>>(d_lines, d_radii, (float)steps, d_origins, steps);

	//Average these distances to find the torus radius
	reduceSum<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float)>>>(d_radii,d_radii);
	reduceSum<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float)>>>(d_radii,d_radii);

	//Copy radii from device to host
	checkCudaErrors(cudaMemcpy(h_radii, d_radii, (dataCount/steps)*sizeof(float), cudaMemcpyDeviceToHost));

	//r_radii are still needed, so no memory free just yet.

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//
	
	//Allocating arrays to store the alpha and beta data to compute winding numbers.
	float* h_windingdata = (float*) malloc((dataCount/steps)*sizeof(float));
	float *d_alpha, *d_beta;
	checkCudaErrors(cudaMalloc(&d_alpha, dataCount*sizeof(float)));
	checkCudaErrors(cudaMalloc(&d_beta, dataCount*sizeof(float)));

	winding<<<dataCount/blockSize,blockSize>>>(d_lines, d_alpha, d_beta, d_origins, d_radii, steps);

	//A check to evaluate the alpha/beta steps found
	float* h_alphacheck = (float*) malloc(steps*sizeof(float));
	checkCudaErrors(cudaMemcpy(h_alphacheck, &d_beta[0], steps*sizeof(float), cudaMemcpyDeviceToHost));

	for(unsigned int i=0; i < 500; i++) {
		std::cout << h_alphacheck[i] << ", ";
	}
	std::cout << std::endl;

	

	//Adding the steps Deltaalpha and Deltabeta to find overall windings
	reduceSum<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float)>>>(d_alpha, d_alpha);
	reduceSum<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float)>>>(d_alpha, d_alpha);

	reduceSum<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float)>>>(d_beta, d_beta);
	reduceSum<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float)>>>(d_beta, d_beta);

	//Dividing these windings to compute the winding numbers and store them in d_alpha
	divide<<<gridSizeRK4,blockSizeRK4>>>(d_alpha, d_beta, d_alpha);

	//Copy winding numbers from from device to host
	checkCudaErrors(cudaMemcpy(h_windingdata, d_alpha, (dataCount/steps)*sizeof(float), cudaMemcpyDeviceToHost));
	
	cudaFree(d_alpha);
	cudaFree(d_beta);
	cudaFree(d_radii);

//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

	//Print some data to screen
	dataprint(h_windingdata,blockSizeRK4);

	//Write all the lines
	datawrite("../datadir/data.bin", dataCount, h_lines);
   
	//Free host pointers
	free(hostvfield[0][0]);
	free(hostvfield[0]);
	free(hostvfield);
	free(h_origins);
	free(h_lines);
	free(h_lengths);
	free(h_windingdata);

	//Free the remaining device pointers
	cudaFree(d_origins);
	cudaFree(d_lines);
	cudaFreeArray(dataArray);
	return 0;
}

