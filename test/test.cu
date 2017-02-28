#include <mat.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <math.h>
#include <matrix.h>
#include <iostream>
#include "cublas_v2.h"
#include "cokus.cpp"
#include "cuda_util.h"
#include <cuda_runtime.h>
using namespace std;

const int KER_NUM = 20;//���������
const int P_NUM = 8;//ÿ�ξ���Ĳ���
const int LEAP = 2;//����
const int GP_NUM = 2;//maxpoolingÿ��ĸ���
const int NEU_NUM1 = 100;
const int NEU_NUM2 = 13;//�������Ԫ����
const int NEIGHBOR = 8;//�����ھӸ���
double LEARN_RATE = 0.008;
const double MIN_ERR = 0.001;
const int VALID_BATCH = 10;

//copy���ݵ�shared memory
__device__ void copy_data_to_shared(double * data, double * data_tmp,int head, int length){
	for(int i=0; i<length; i++){
		data_tmp[i] = data[i+head];
	}

	__syncthreads();
}

//GPU�˸�����
__global__ static void convol(int iter,int i0,double * train,double * kernel,double * re,double * bias,int x,int y,int z,int re_size)
{
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;//���浱ǰ�̱߳��

	//ÿ���̸߳���һ���������һ��3*3*hight��״ͼ��ľ��
	if (id < KER_NUM){
		extern __shared__ double train_tmp[];
		//__shared__ double train_tmp[9*200];
		int st = i0 * x * y * z;

		copy_data_to_shared(train,train_tmp,st,x*y*z);//����train��shared memory��

		/*double * ker = new double [x*y*P_NUM];//�����Ӧ��kernel���Ĵ���
		for(int i=0; i<x*y*P_NUM; i++){
			ker[i] = kernel[id*x*y*P_NUM + i];
		}*/
		double mid;
		//int i_1=0;
		for(int i=0; i<re_size; i++){
			mid = 0;
			int start = i*x*y*LEAP;//ѵ������ÿ�ξ�������
			for(int j=0; j<x*y*P_NUM; j++){
				mid = mid + train_tmp[start + j]*kernel[id*x*y*P_NUM+j];
			}
			mid = mid + bias[id];
			re[i + id*re_size] = 2/(1+(1/exp(2*mid))) - 1;//�����tanh
		}
		/*for
		}*/
	}
}

//GPU�˽����²���
__global__ static void maxpooling(int iter,double * re,double * mre,int * mre_index,int re_size,int mre_num){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
       	int id = tid + iter * threadNum; 
	
	//int res = re_size, mres = mre_num;
	//extern __shared__ double re_tmp[];
	//copy_data_to_shared(re, re_tmp, 0, re_size*KER_NUM);

	if(id < KER_NUM){
		double mid;
		int mid_index;
		for(int i=0; i<mre_num; i++){
			mid = re[i*GP_NUM + id*re_size];//���ÿ���һ��ֵ
			mid_index = i*GP_NUM + id*re_size;
			for(int j=i*GP_NUM+1; j<(i+1)*GP_NUM && j<re_size; j++){
				if(mid < re[j + id*re_size]){
					mid = re[j + id*re_size];
					mid_index = j+id*re_size;
				}
			}
			mre[i + id * mre_num] = mid;
			mre_index[i + id * mre_num] = mid_index;
		}
	}
}

//ȫ���Ӳ�,ÿ���̸߳���һ����Ԫ�������ļ���
__global__ static void fullconnect(int iter,double * mre,double * omega,double * bias,double * F1,int mre_size){
	int tid = blockIdx.x * blockDim.x +threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;

	if(id < NEU_NUM1){
		//����mre���鵽�����ڴ�
		//__shared__ double mre_tmp[50 * KER_NUM];
	        extern __shared__ double mre_tmp[];	
		copy_data_to_shared(mre,mre_tmp,0,mre_size);
		
		//������Ԫ�����
		double mid=0;
		for(int i=0; i<mre_size; i++){
			mid = mid + omega[id + i*NEU_NUM1] * mre_tmp[i];
		}
		mid = mid + bias[id];
		F1[id] = 2/(1 + 1/exp(mid * 2)) - 1;//�����tanh
	}
}

//����㣬ÿ���̸߳���һ����Ԫ�������ļ���
__global__ static void output(int iter, double * F1, double * omega2, double * bias, double * O2){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;

	if(id < NEU_NUM2){
		//����F1�������ڴ���
		__shared__ double F1_tmp[NEU_NUM1];
		copy_data_to_shared(F1, F1_tmp, 0, NEU_NUM1);
		__shared__ double O2_tmp[NEU_NUM2];

		//������Ԫ�����
		double mid = 0;
		for(int i=0; i<NEU_NUM1; i++){
			mid = mid + omega2[id + i*NEU_NUM2] * F1_tmp[i];
		}
		O2[id] = exp(mid+ bias[id]);
		O2_tmp[id] = O2[id];
		__syncthreads(); //�ȴ������߳̽���Ԫ������������SM

		//����softmax�������������
		int length = NEU_NUM2;//��ǰ��Ҫ�ۼӵ����鳤��
		int offset = (length - 1)/2 +1;//�ۼӵ�ƫ��ֵ
		while(length >= 2)
		{
			if(id + offset < length){
				O2_tmp[id] = O2_tmp[id] + O2_tmp[id + offset];
			}
			offset = (offset - 1)/2 + 1;
			length = (length - 1)/2 + 1;
			__syncthreads();//�ȴ������߳���ɵ�ǰ���ۼ�
		}
		O2[id] = O2[id]/O2_tmp[0];

	}
}

//������ȷ��
double count_err(double * test_labels, double * output, int test_idx)
{
	double right=0;
	double max =0;
	int idx = 0;
	for(int i=0; i<NEU_NUM2; i++){
		if(output[i]>max){
			max = output[i];
			idx = i;
		}
	}
	if((idx+1) == int(test_labels[test_idx]))
		right = 1;
	
	return right;
}

double testint(int test_size, int data_size, double * test_data, double * test_labels, double * kernel, double * omega1, double * omega2, double * bias0, double * bias1, double * bias2)
{
		double * gpu_processed_test;
		double * gpu_kernel;
		double * gpu_omega1;
		double * gpu_omega2;
		double * gpu_bias0;
		double * gpu_bias1;
		double * gpu_bias2;
		double * gpu_re;
		double * gpu_mre;
		double * gpu_mre_index;
		double * gpu_F1;
		double * gpu_O2;
		
			//����ÿ�ξ���Ľ������
		int re_size = 0;
		for (int i=0; i+P_NUM-1<z; i+=LEAP){
			re_size ++;
		}
		int mre_num = (re_size-1)/GP_NUM + 1;
		int mre_size = mre_num * KER_NUM;
		int ome_num1 = mre_num * KER_NUM * NEU_NUM1;//��һ�����������Ȩ�ظ���
		int ome_num2 = NEU_NUM1 * NEU_NUM2;//������Ȩ�ظ���	
		
		SAFE_CALL(cudaMalloc((void **) &gpu_processed_test, sizeof(double) * data_size));
		SAFE_CALL(cudaMalloc((void **) &gpu_kernel,sizeof(double) * (NEIGHBOR+1) * P_NUM * KER_NUM));
		SAFE_CALL(cudaMalloc((void **) &gpu_omega1, sizeof(double) * ome_num1));//��һ�����������Ȩ�أ������Դ�
		SAFE_CALL(cudaMalloc((void **) &gpu_omega2, sizeof(double) * ome_num2));//������Ȩ�أ������Դ�
		SAFE_CALL(cudaMalloc((void **) &gpu_bias0, sizeof(double) * KER_NUM));//�����ƫ��ֵ
		SAFE_CALL(cudaMalloc((void **) &gpu_bias1, sizeof(double) * NEU_NUM1));//ȫ���Ӳ�ƫ��ֵ
		SAFE_CALL(cudaMalloc((void **) &gpu_bias2, sizeof(double) * NEU_NUM2));//�����ƫ��
		SAFE_CALL(cudaMalloc((void **) &gpu_re,sizeof(double) * re_size * KER_NUM));
		SAFE_CALL(cudaMalloc((void **) &gpu_mre, sizeof(double) * mre_num * KER_NUM));//maxpooling�������gpu_mre�������Դ�
		SAFE_CALL(cudaMalloc((void **) &gpu_mre_index, sizeof(int) * mre_num * KER_NUM));//Ϊmaxpooling�����ֵ���������Դ�
		SAFE_CALL(cudaMalloc((void **) &gpu_F1, sizeof(double) * NEU_NUM1));//��һ�����������������Դ�
		SAFE_CALL(cudaMalloc((void **) &gpu_O2, sizeof(double) * NEU_NUM2));//�����Ľ��
		
		SAFE_CALL(cudaMemcpy(gpu_processed_test,test_data,sizeof(double) * (NEIGHBOR+1) * data_size, cudaMemcpyHostToDevice));
		SAFE_CALL(cudaMemcpy(gpu_kernel,kernel,sizeof(double) * (NEIGHBOR+1) * P_NUM * KER_NUM,cudaMemcpyHostToDevice));
		SAFE_CALL(cudaMemcpy(gpu_omega1, omega1, sizeof(double) * ome_num1, cudaMemcpyHostToDevice));//���Ƴ�ʼȨ�ص�GPU��
		SAFE_CALL(cudaMemcpy(gpu_omega2, omega2, sizeof(double) * ome_num2, cudaMemcpyHostToDevice));
		SAFE_CALL(cudaMemcpy(gpu_bias0, bias0, sizeof(double) * KER_NUM, cudaMemcpyHostToDevice));
		SAFE_CALL(cudaMemcpy(gpu_bias1, bias1, sizeof(double) * NEU_NUM1, cudaMemcpyHostToDevice));//����ƫ��ֵ���Դ�
		SAFE_CALL(cudaMemcpy(gpu_bias2, bias2, sizeof(double) * NEU_NUM2, cudaMemcpyHostToDevice));
		
		double right = 0;
		double count0 = 0;
		for (int i1=0; i1<test_size; i1++){
			int iter = 0;
			convol<<<1,KER_NUM,(NEIGHBOR+1)*z*sizeof(double)>>>(iter,i1,gpu_processed_test,gpu_kernel,gpu_re,gpu_bias0,3,3,z,re_size);
			cudaDeviceSynchronize();

			maxpooling<<<1,KER_NUM>>>(iter,gpu_re,gpu_mre,gpu_mre_index,re_size,mre_num);
			cudaDeviceSynchronize();

			fullconnect<<<1,NEU_NUM1,mre_size * sizeof(double)>>>(iter,gpu_mre,gpu_omega1,gpu_bias1,gpu_F1,mre_size);
			cudaDeviceSynchronize();

			output<<<1,NEU_NUM2>>>(iter,gpu_F1,gpu_omega2,gpu_bias2,gpu_O2);
			cudaDeviceSynchronize();

			SAFE_CALL(cudaMemcpy(O2, gpu_O2, sizeof(double) * NEU_NUM2, cudaMemcpyDeviceToHost));
			cudaDeviceSynchronize();

			//fprintf(stdout,"\n");
			right = count_err(test_labels, O2, i1);
			count0 = count0 + right;
		}
		
		return count0/test_size;
}
int main(int argc, char * argv[])
{
	clock_t start,end;

	double * kernel,* omega1, * omega2, * bias0, * bias1, * bias2;
	if(argc!=3){
		fprintf(stderr, "3 input arguments required!");
	}
	MATFile * datamat = matOpen(argv[1], "r");
	mxArray * ker = matGetVariable(datamat,"kernel");
	mxArray * ome1 = matGetVariable(datamat,"omega1");
	mxArray * ome2 = matGetVariable(datamat,"omega2");
	mxArray * b0 = matGetVariable(datamat,"bias0");
	mxArray * b1 = matGetVariable(datamat,"bias1");
	mxArray * b2 = matGetVariable(datamat,"bias2");

	kernel = (double*)mxGetData(ker);
	omega1 = (double*)mxGetData(ome1);
	omega2 = (double*)mxGetData(ome2);
	bias0 = (double*)mxGetData(b0);
	bias1 = (double*)mxGetData(b1);
	bias2 = (double*)mxGetData(b2);
	matClose(datamat);
	
	double * test_data, * test_labels;
	MATFile * testmat = matOpen(argv[2], "r");
	mxArray * data = matGetVariable(testmat,"data");
	mxArray * labels = matGetVariable(testmat,"labels");
	
	test_data = (double*)mxGetData(data);
	test_labels	= (double*)mxGetData(labels);
	const mwSize  * dim0, *dim1;
	dim0 = mxGetDimensions(labels);//��ȡ���Լ�����
	dim1 = mxGetDimensions(data);//��ȡ���Լ���ģ
	matClose(testmat);

	double corr = testing(dim0[0],dim1[0] * dim1[1] * dim1[2],test_data,test_labels,kernel,omega1,omega2,bias0,bias1,bias2);	
}