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

void dataprint (float4* data, dim3 Size) {
	for(unsigned int i=0; i< Size.x; i++) {
		for(unsigned int j=0; j< Size.y; j++) {
			std::cout << data[Size.y*i+j].x << ", "<< data[Size.y*i+j].y << ", "<< data[Size.y*i+j].z << std::endl;
		}
		std::cout << std::endl;
	}
}

int main(int argc, char *argv[]) {

	struct cudaDeviceProp properties;
	cudaGetDeviceProperties(&properties, 0);
	std::cout<<"using "<<properties.multiProcessorCount<<" multiprocessors"<<std::endl;
	std::cout<<"max threads per processor: "<<properties.maxThreadsPerMultiProcessor<<std::endl;

	//Check if the input is sensible
	std::string name;
	if (argc == 1) {
		std::cout << "Please specify as an argument the path to the .vtk file to use"  << std::endl;
		return 1;
	} else {
		name = argv[1];
	}
	if (name.rfind(".vtk") == std::string::npos) {
		name.append(".vtk");
	}
	//Allocate data array on host
	float4*** hostvfield;
	allocarray(hostvfield);

	//Read data from file specified as argument
	float4 dataorigin = {0,0,0,0};
	vtkDataRead(hostvfield[0][0], name.c_str(), dataorigin);
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
	copyParms.srcPtr = make_cudaPitchedPtr((void *)hostvfield[0][0],
		   	extent.width*sizeof(float4),
		   	extent.height,
		   	extent.depth
			);
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
	float dt = 0;

	dim3 BIGgridSize(64,64);
	dim3 gridSizeRK4(2,2);
	dim3 blockSizeRK4(32,32); //gridSizeRK4*blockSizeRK4*steps should not exceed 2^26, to fit on 4GB VRAM
	//gridsizeRK4*blockSizeRK4 should be at least 2*blockSize

	int dataCount = gridSizeRK4.x*gridSizeRK4.y*blockSizeRK4.x*blockSizeRK4.y*steps;
	int BIGnroflines = BIGgridSize.x*BIGgridSize.y*blockSizeRK4.x*blockSizeRK4.y;

	float4 BIGstartloc = make_float4(0,0,-1,0); //Location (in Smietcoords) to start the 
//	integration, to be varied
	float4 BIGxvec = {2,0,0,0};
	float4 BIGyvec = {0,0,2,0};

	//Allocate host arrays for the winding numbers,
	float* h_windingdata;
	cudaError_t status = cudaMallocHost((void**)&h_windingdata,BIGnroflines*sizeof(float));
	if (status != cudaSuccess)
		printf("Error allocating pinned host memory.\n");
	
	//Allocate space on device & host to store integration output
	const bool WRITELINES = true;
	checkCudaErrors(cudaMalloc(&d_lines, dataCount*sizeof(float4)));
	if (WRITELINES == true) {
		h_lines = (float4*) malloc(dataCount*sizeof(float4));
	}

	//Allocate space to store origin data
	float4 *d_origins;
	checkCudaErrors(cudaMalloc(&d_origins, dataCount/(2*blockSize)*sizeof(float4)));
	float4 *d_origin;
	checkCudaErrors(cudaMalloc(&d_origin, sizeof(float4)));


	//Allocating the array to store the length data, both for host and device
	float *d_lengths, *h_lengths;
	checkCudaErrors(cudaMalloc(&d_lengths, dataCount*sizeof(float)));
	status = cudaMallocHost((void**)&h_lengths, BIGnroflines*sizeof(float));
	if (status != cudaSuccess)
		printf("Error allocating pinned host memory.\n");
	
	float cent_fac = 1/4.;
	float4 centreEdgeGuess = BIGstartloc+(BIGxvec+BIGyvec)*(1-cent_fac)/2.0;

	float4 centrexvec = BIGxvec*cent_fac;
	float4 centreyvec = BIGyvec*cent_fac;

	RK4init<<<gridSizeRK4,blockSizeRK4,0>>>(d_lengths, centreEdgeGuess, centrexvec, centreyvec);
	reduceSum<float><<<gridSizeRK4.x*gridSizeRK4.y/2,blockSizeRK4.x*blockSizeRK4.y,blockSizeRK4.x*blockSizeRK4.y*sizeof(float)>>>
		(d_lengths, d_lengths);
	reduceSum<float><<<1,gridSizeRK4.x*gridSizeRK4.y/4,gridSizeRK4.x*gridSizeRK4.y/4*sizeof(float)>>>
		(d_lengths, d_lengths);
	checkCudaErrors(cudaMemcpy(&dt, d_lengths,sizeof(float),cudaMemcpyDeviceToHost));
	dt/=(float)(dataCount/steps);
	std::cout << "B_length mean = " << dt << std::endl;
	dt = (1.0/32.0)/dt;
	cudaFree(d_lengths);

	RK4line<<<gridSizeRK4,blockSizeRK4,0>>>(d_lines, dt, steps, centreEdgeGuess, centrexvec, centreyvec);
	reduceSum<float4><<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float4)>>>
		(d_lines, d_origins);
	reduceSum<float4><<<dataCount/(4*blockSize*blockSize),blockSize,blockSize*sizeof(float4)>>>
		(d_origins, d_origins);
	reduceSum<float4><<<1,dataCount/(8*blockSize*blockSize),dataCount/(8*blockSize*blockSize)*sizeof(float4)>>>
		(d_origins, d_origin);
	divide<<<1,1,0>>>
		(d_origin,(float)dataCount, d_origin);
//	float4 h_origin;
//	checkCudaErrors(cudaMemcpy(&h_origin, d_origin, sizeof(float4),cudaMemcpyDeviceToHost));
//	std::cout << h_origin.y << std::endl;
	cudaFree(d_origins);


	float4 *d_normals;
	checkCudaErrors(cudaMalloc(&d_normals, dataCount*sizeof(float4)));
	float4 *d_normal;
	checkCudaErrors(cudaMalloc(&d_normal, sizeof(float4)));

	normal<<<dataCount/blockSize,blockSize,0>>>
		(d_lines, d_normals, d_origin);
	reduceSum<float4><<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float4)>>>
		(d_normals, d_normals);
	reduceSum<float4><<<dataCount/(4*blockSize*blockSize),blockSize,blockSize*sizeof(float4)>>>
		(d_normals, d_normals);
	reduceSum<float4><<<1,dataCount/(8*blockSize*blockSize),dataCount/(8*blockSize*blockSize)*sizeof(float4)>>>
		(d_normals, d_normal);
	divide<<<1,1,0>>>
		(d_normal,(float)dataCount, d_normal);//not size-scalable!!!
	float4 h_normal;
	checkCudaErrors(cudaMemcpy(&h_normal, d_normal, sizeof(float4),cudaMemcpyDeviceToHost));
	std::cout << h_normal.x << ", y:" << h_normal.y << ", z: " <<h_normal.z << std::endl;
	
	cudaFree(d_normals);

	//Allocating the array to store the radius data, both for host and device
	float *d_radius, *d_radiimin, *d_radiimax;
	checkCudaErrors(cudaMalloc(&d_radiimin, dataCount*sizeof(float)));
	checkCudaErrors(cudaMalloc(&d_radiimax, dataCount*sizeof(float)));
	checkCudaErrors(cudaMalloc(&d_radius, sizeof(float4)));

	//Compute the distance from the origin in the xy plane of each point
	rxy<<<dataCount/blockSize,blockSize,0>>>
		(d_lines, d_radiimin, (float)steps, d_origin, d_normal);
	rxy<<<dataCount/blockSize,blockSize,0>>>
		(d_lines, d_radiimax, (float)steps, d_origin, d_normal);

	//minmax these distances to find the torus radius
	reduceMin<float><<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float)>>>
		(d_radiimin,d_radiimin);
	reduceMin<float><<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float)>>>
		(d_radiimin,d_radiimin);
	reduceMax<float><<<dataCount/(2*blockSize*steps),blockSize,blockSize*sizeof(float)>>>
		(d_radiimin,d_radiimin);
	reduceMax<float><<<1,dataCount/(4*blockSize*steps),dataCount/(4*blockSize*steps)*sizeof(float)>>>
		(d_radiimin,d_radiimin);
	float radiimin,radiimax;
	checkCudaErrors(cudaMemcpy(&radiimin, d_radiimin, sizeof(float),cudaMemcpyDeviceToHost));
	
	reduceMax<float><<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float)>>>
		(d_radiimax,d_radiimax);
	reduceMax<float><<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float)>>>
		(d_radiimax,d_radiimax);
	reduceMin<float><<<dataCount/(2*blockSize*steps),blockSize,blockSize*sizeof(float)>>>
		(d_radiimax,d_radiimax);
	reduceMin<float><<<1,dataCount/(4*blockSize*steps),dataCount/(4*blockSize*steps)*sizeof(float)>>>
		(d_radiimax,d_radiimax);
	checkCudaErrors(cudaMemcpy(&radiimax, d_radiimax, sizeof(float),cudaMemcpyDeviceToHost));
	std::cout << "min: " << radiimin << ", max: " << radiimax << std::endl;
	average<<<1,1,0>>>(d_radiimax,d_radiimin,d_radius);

	cudaFree(d_radiimin);
	cudaFree(d_radiimax);
	
	//Declaring arrays to save the winding data
	float *d_alpha, *d_beta;
	checkCudaErrors(cudaMalloc(&d_alpha, dataCount*sizeof(float)));
	checkCudaErrors(cudaMalloc(&d_beta, dataCount*sizeof(float)));

	//Set up streams for independent execution
	cudaStream_t RK4, windings, windings2, lengths;
	status = cudaStreamCreate(&RK4);
	status = cudaStreamCreate(&windings);
	status = cudaStreamCreate(&windings2);
	status = cudaStreamCreate(&lengths);

	//Start main loop.
	for (int yindex = 0; yindex < BIGgridSize.y; yindex += gridSizeRK4.y) {
		for (int xindex = 0; xindex < BIGgridSize.x; xindex += gridSizeRK4.x) {

			std::cout << "x" << std::flush;
			float4 startloc = BIGstartloc + ((float)xindex/BIGgridSize.x) * BIGxvec + ((float)yindex/BIGgridSize.y) * BIGyvec;
			float4 xvec = BIGxvec * ((float)gridSizeRK4.x/BIGgridSize.x);
			float4 yvec = BIGyvec * ((float)gridSizeRK4.y/BIGgridSize.y);

			int globaloffset = yindex*blockSizeRK4.y*BIGgridSize.x*blockSizeRK4.x+xindex*blockSizeRK4.x;

			int hsize = gridSizeRK4.x*blockSizeRK4.x;
			int vsize = gridSizeRK4.y*blockSizeRK4.y;

		//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

			cudaDeviceSynchronize();	
			cudaStreamSynchronize(windings);
			cudaStreamSynchronize(lengths);
			//Integrate the vector field
			RK4line<<<gridSizeRK4,blockSizeRK4,0,RK4>>>(d_lines, dt, steps, startloc, xvec, yvec);

			//Copy data from device to host
			if(yindex == BIGgridSize.y/2 && xindex == BIGgridSize.x/2 && WRITELINES == true) {
				checkCudaErrors(cudaMemcpyAsync(
						h_lines,
						d_lines,
						dataCount*sizeof(float),
						cudaMemcpyDeviceToHost,
						RK4
						));
				cudaStreamSynchronize(RK4);
			}

		//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//

			cudaStreamSynchronize(RK4);//Wait for d_lines to be filled
	
			//Compute the length of each line (locally)
			lineLength<<<dataCount/blockSize,blockSize,0,lengths>>>(d_lines, dt, d_lengths);

			//Add the length of the pieces of the lines to obtain line length
			//Stores the length of the i'th line in d_lengths[i]
			reduceSum<float><<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float),lengths>>>
				(d_lengths,d_lengths);
			reduceSum<float><<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float),lengths>>>
				(d_lengths,d_lengths);

			//Copy lengths from device to host
			//Note: can be even more asynchronous and should copy to different parts of h_lengths.
			checkCudaErrors(cudaMemcpy2DAsync(
						&(h_lengths[globaloffset]),
						BIGgridSize.x*blockSizeRK4.x*sizeof(float),
					   	d_lengths,
						hsize*sizeof(float), 
						hsize*sizeof(float), 
						vsize, 
						cudaMemcpyDeviceToHost,
						lengths
						));

		//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//
			
			cudaStreamSynchronize(lengths);
			//Make sure data from previous iteration is copied away to host
			cudaStreamSynchronize(windings2);
		//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//
			winding<<<dataCount/blockSize,blockSize,0,windings>>>(d_lines, d_alpha, d_beta, 
d_origin, d_radius, d_normal, steps);

			//Adding the steps Deltaalpha and Deltabeta to find overall windings
			//This code is dependent on completion of winding, but independent on d_lines
			cudaStreamSynchronize(windings);//Wait for d_lines to be filled
			reduceSum<float>
				<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float),windings2>>>
				(d_alpha, d_alpha);
			reduceSum<float>
				<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float),windings2>>>
				(d_alpha, d_alpha);

			reduceSum<float>
				<<<dataCount/(2*blockSize),blockSize,blockSize*sizeof(float),windings2>>>
				(d_beta, d_beta);
			reduceSum<float>
				<<<dataCount/steps,steps/(4*blockSize),steps/(4*blockSize)*sizeof(float),windings2>>>
				(d_beta, d_beta);

			//Dividing these windings to compute the winding numbers and store them in d_alpha
			divide<<<dataCount/(steps*blockSize),blockSize,0,windings2>>>
				(d_beta, d_alpha, d_alpha);//Not Scalable!!!

//			cudaDeviceSynchronize();	
			checkCudaErrors(cudaMemcpy2DAsync(
						&(h_windingdata[globaloffset]),
						BIGgridSize.x*blockSizeRK4.x*sizeof(float),
					   	d_alpha,
						hsize*sizeof(float), 
						hsize*sizeof(float), 
						vsize, 
						cudaMemcpyDeviceToHost,
						windings2
						));
		}
		std::cout << std::endl;
	}

		//%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%//
		   

	//Free the remaining device pointers
	cudaFree(d_alpha);
	cudaFree(d_beta);
	cudaFree(d_radius);
	cudaFree(d_lengths);
	cudaFree(d_origin);
	cudaFree(d_lines);

//Print some data to screen
	//	dim3 printtest(16,16);
	//	dataprint(h_windingdata,printtest);
//Write some data
//	float4write("../datadir/linedata.bin", BIGdataCount, h_lines);
	name = name.substr(name.rfind("/")+1,name.rfind(".")-name.rfind("/")-1);
	const std::string prefix = "../datadir/shafranov3/2k";
	std::string suffix = "_windings.bin";
	std::string path = prefix+name+suffix;
	floatwrite(path.c_str(), BIGnroflines, h_windingdata);
	suffix = "_lengths.bin";
	path = prefix+name+suffix;
	floatwrite(path.c_str(), BIGnroflines, h_lengths);
	
	if(WRITELINES) {
		suffix = "_lines.bin";
		path = prefix+name+suffix;
		float4write(path.c_str(), dataCount, h_lines);
		free(h_lines);
	}
	status = cudaStreamDestroy(RK4);
	status = cudaStreamDestroy(windings);
	status = cudaStreamDestroy(lengths);

	//Free host pointers

	free(hostvfield[0][0]);
	free(hostvfield[0]);
	free(hostvfield);

	cudaFreeHost(h_windingdata);
	cudaFreeArray(dataArray);
	cudaFreeHost(h_lengths);
	return 0;
}

