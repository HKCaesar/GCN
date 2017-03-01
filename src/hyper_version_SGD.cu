#include <mat.h>
#include <stdio.h>
#include <time.h>
#include <sys/time.h>
#include <math.h>
#include <matrix.h>
#include <iostream>
//#include "cublas_v2.h"
#include "cokus.cpp"
#include "cuda_util.h"
#include <cuda_runtime.h>
using namespace std;

const int KER_NUM = 20;//number of convolution kernels
const int P_NUM = 19;//number of layers to be convoluted
const int LEAP = 2;//leap size
const int GP_NUM = 2;//number of each group of maxpooling layer
const int NEU_NUM1 = 100;
const int NEU_NUM2 = 13;//number of output layer neurons 
const int NEIGHBOR = 0;//number of neighbors
double LEARN_RATE = 0.007;
const double MIN_ERR = 0.0003;
const int VALID_BATCH = 5;
const int MAX_MRE = 2000;

//Initialize CUDA
bool InitCUDA(){
	int count;
	cudaGetDeviceCount(&count);
	if(count==0){
		fprintf(stderr,"There is no device.\n");
		return false;
	}
	int i;
	for (i =0; i<count;i++){
		cudaDeviceProp prop;
		if(cudaGetDeviceProperties(&prop,i)==cudaSuccess){
			if(prop.major>=1){     
				break;
			}
		}
	}
	if(i==count){
		fprintf(stderr,"There is no device supporting CUDA 1.x.\n");
		return false;
	}
	cudaSetDevice(i);
	return true;
}


//copy data to shared memory
__device__ void copy_data_to_share(double * data, double data_tmp[1][MAX_MRE],int tid, int offset,int head,int length){
	for(int i=tid*offset; i<(tid+1)*offset && (i < length); i++){
		data_tmp[0][i] = data[i+head];
	}
	__syncthreads();

	/*for(int i=0;i<length;i++){
		data_tmp[0][i] = data[head + i];
	}*/
}

__device__ void copy_data_to_shared(double * data, double * data_tmp, int head, int length){
	for(int i=0;i<length;i++){
		data_tmp[i] = data[i + head];
	}
}

//forward convolutional kernel
__global__ static void convol(int iter,int i0,double * train,double * kernel,double * re,double * bias,int z,int re_size)
{
/*	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;//保存当前线程编号

	//每个线程负责一个卷积核与一个3*3*hight柱状图像的卷积
	if (id < KER_NUM){
		__shared__ double train_tmp[1][MAX_MRE];
		int head = i0 * x * y * z;
		int length = x * y * z;
		int offset = (length - 1)/KER_NUM + 1;
		copy_data_to_share(train,train_tmp,id,offset,head,x*y*z);//复制train到shared memory中
		__syncthreads();
		//copy_data_to_share(train,train_tmp,head,length);
		
		double mid;
		int start, i, j;
		for(i=0; i<re_size; i++){
			mid = 0;
			start = i*x*y*LEAP;//训练数据每次卷积的起点
			for(j=0; j<x*y*P_NUM; j++){
				mid = mid + train_tmp[0][start + j]*kernel[id*x*y*P_NUM + j];
			}
			mid = mid + bias[id];
			re[i + id*re_size] = 2/(1+(1/exp(2*mid))) - 1;//激活函数tanh
		}
	}
*/
	int tid = threadIdx.x;
	int bid = blockIdx.x;

	if(tid<re_size && bid < KER_NUM)
	{
		__shared__ double train_tmp[1][MAX_MRE];
		int head = i0*(NEIGHBOR+1)*z;
		int length = (NEIGHBOR+1)*z;
		int offset = (length - 1)/re_size + 1;
		copy_data_to_share(train,train_tmp,tid,offset,head,(NEIGHBOR+1)*z);
		__shared__ double kernel_tmp[1][MAX_MRE];
		head = bid * (NEIGHBOR+1) * P_NUM;
		length = (NEIGHBOR+1)*P_NUM;
		offset = (length - 1)/re_size + 1;
		copy_data_to_share(kernel,kernel_tmp,tid,offset,head,length);
		__syncthreads();

		double mid = 0;
		for(int i=0;i<(NEIGHBOR+1)*P_NUM;i++){
			mid = mid + kernel_tmp[0][i] * train_tmp[0][tid*(NEIGHBOR+1)*LEAP + i];
		}
		mid = mid + bias[bid];
		re[tid + bid*re_size] = 2/(1 + (1/exp(2*mid))) - 1;
	}
}

//forward maxpooling layer
__global__ static void maxpooling(int iter,double * re,double * mre,int * mre_index,int re_size,int mre_num){
	/*int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
       	int id = tid + iter * threadNum; 
	
	if(id < KER_NUM){
		double mid;
		int mid_index;
		for(int i=0; i<mre_num; i++){
			mid = re[i*GP_NUM + id*re_size];//存放每组第一个值
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
	}*/
	int tid = threadIdx.x;
	int bid = blockIdx.x;
	if(tid<mre_num && bid<KER_NUM){
		double mid;
		int mid_index, head, tail;
		head = tid*GP_NUM + bid*re_size;
		tail = (tid+1)*GP_NUM + bid*re_size ;
		mid = re[head];
		mid_index = head;
		for(int i=head; i<tail && (i<(bid+1)*re_size); i++){
			if(mid < re[i]){
				mid = re[i];
				mid_index=i;
			}
		}
		mre[tid + bid*mre_num] = mid;
		mre_index[tid + bid*mre_num] = mid_index;
	}
}

//forward fullconnect layer
__global__ static void fullconnect(int iter,double * mre,double * omega,double * bias,double * F1,int mre_size){
	/*int tid = blockIdx.x * blockDim.x +threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;

	if(id < NEU_NUM1){
		//复制mre数组到共享内存
		//__shared__ double mre_tmp[50 * KER_NUM];
	        extern __shared__ double mre_tmp[];	
		copy_data_to_shared(mre,mre_tmp,0,mre_size);
		
		//计算神经元的输出
		double mid=0;
		for(int i=0; i<mre_size; i++){
			mid = mid + omega[id + i*NEU_NUM1] * mre_tmp[i];
		}
		mid = mid + bias[id];
		F1[id] = 2/(1 + 1/exp(mid * 2)) - 1;//激活函数tanh
	}*/
	int tid = threadIdx.x;
	int bid = blockIdx.x;
	if(tid<mre_size && bid<NEU_NUM1){
		__shared__ double ner[1][MAX_MRE];
		ner[0][tid] = omega[bid + tid*NEU_NUM1] * mre[tid];
		__syncthreads();//等待所有线程计算完成

		int length = mre_size;
		int offset = (length - 1)/2 + 1;

		while(length >= 2)
		{
			if(tid + offset < length)
			{
				ner[0][tid] = ner[0][tid] + ner[0][tid + offset];
			}
			offset = (offset - 1)/2 + 1;
			length = (length - 1)/2 + 1;
			__syncthreads();
		}

		F1[bid] = 2/(1 + 1/exp((ner[0][0] + bias[bid]) * 2)) - 1;
	}
}

//forward output layer
__global__ static void output(int iter, double * F1, double * omega2, double * bias, double * O2){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;

	if(id < NEU_NUM2){
		//复制F1到共享内存中
		__shared__ double F1_tmp[1][MAX_MRE];
		int offset = (NEU_NUM1-1)/NEU_NUM2 + 1;
		copy_data_to_share(F1, F1_tmp, id, offset, 0, NEU_NUM1);
		__syncthreads();
		__shared__ double O2_tmp[1][NEU_NUM2];

		//计算神经元的输出
		double mid = 0;
		for(int i=0; i<NEU_NUM1; i++){
			mid = mid + omega2[id + i*NEU_NUM2] * F1_tmp[0][i];
		}
		O2[id] = exp(mid+ bias[id]);
		O2_tmp[0][id] = O2[id];
		__syncthreads(); //等待所有线程将神经元输出结果加载入SM

		//计算softmax激活函数的输出结果
		int length = NEU_NUM2;//当前需要累加的数组长度
		offset = (length - 1)/2 +1;//累加的偏移值
		while(length >= 2)
		{
			if(id + offset < length){
				O2_tmp[0][id] = O2_tmp[0][id] + O2_tmp[0][id + offset];
			}
			offset = (offset - 1)/2 + 1;
			length = (length - 1)/2 + 1;
			__syncthreads();//等待所有线程完成当前的累加
		}
		O2[id] = O2[id]/O2_tmp[0][0];

	}
}

__global__ static void bp_output(int iter,int train_idx, double LEARN_RATE, double * labels, double * O2, double * bias2, double * delta_L_z)
{
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;
	if(id < NEU_NUM2){
		//delta_L_a[id] = -(labels[id + train_idx * NEU_NUM2] - O2[id]);
		delta_L_z[id] = (O2[id] - labels[id + train_idx * NEU_NUM2])/NEU_NUM2;
		bias2[id] = bias2[id] - delta_L_z[id]*LEARN_RATE;
	}
}
//backward fullconnect layer
__global__ static void bp_fullconnect(int iter, double LEARN_RATE, double * omega2,double * bias1, double * F1, double * delta_L_z, double *delta_f_a, double * delta_f_z)
{
	/*int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;
	if(id < NEU_NUM1){
		double mid = 0;
		double delta_f_w;

		for(int i=0; i<NEU_NUM2; i++){
			mid = mid + omega2[i + id*NEU_NUM2] * delta_L_z[i];
			//delta_f_b[i] = delta_L_z[i];
			delta_f_w = F1[id] * delta_L_z[i];

			omega2[i + id*NEU_NUM2] = omega2[i + id*NEU_NUM2] - LEARN_RATE * delta_f_w;
			//bias2[i] = bias2[i] - LEARN_RATE*delta_f_b[i];
		}
		delta_f_a[id] = mid;
		delta_f_z[id] = delta_f_a[id] * (1 + F1[id]) * (1 - F1[id]);
		bias1[id] = bias1[id] - LEARN_RATE * delta_f_z[id];
	}*/
	int tid = threadIdx.x;
	int bid = blockIdx.x;
	if(tid<NEU_NUM2 && bid<NEU_NUM1){
		__shared__ double dfa[1][NEU_NUM2];
		dfa[0][tid] = omega2[tid + bid*NEU_NUM2] * delta_L_z[tid];
		__syncthreads();

		omega2[tid + bid*NEU_NUM2] = omega2[tid + bid*NEU_NUM2] - LEARN_RATE * F1[bid] * delta_L_z[tid];

		int length = NEU_NUM2;
		int offset = (length - 1)/2 + 1;
		while(length >= 2){
			if(tid + offset < length){
				dfa[0][tid] = dfa[0][tid] + dfa[0][tid+offset];
			}
			length = (length - 1)/2 + 1;
			offset = (offset - 1)/2 + 1;
			__syncthreads();
		}

		delta_f_a[bid] = dfa[0][0];
		delta_f_z[bid] = dfa[0][0] * (1 + F1[bid]) * (1 - F1[bid]);
		if(tid < 1){
			bias1[bid] = bias1[bid] - LEARN_RATE * delta_f_z[bid];
		}
	}
}
//bacdward maxpooling layer
__global__ static void bp_maxpooling(int iter, int mre_size,double LEARN_RATE, int *mre_index, double * omega1,double *mre, double * delta_f_a, double * delta_f_z, double * delta_22)
{
	/*int tid = blockIdx.x * blockDim.x + threadIdx.x;
        int threadNum = blockDim.x * gridDim.x;
        int id = tid + iter * threadNum;
	if(id < mre_size){
		double mid = 0;
		double delta_m_w;
		for(int i=0; i<NEU_NUM1; i++){
			mid = mid + omega1[i + id*NEU_NUM1] * delta_f_z[i];
			//delta_2[i + id*NEU_NUM1] = mid;
			delta_m_w = mre[id] * delta_f_z[i];
			omega1[i + id*NEU_NUM1] = omega1[i + id*NEU_NUM1] - LEARN_RATE * delta_m_w;
		}
		delta_m_a[id] = mid;
		//delta_2[id] = delta_m_a[id];
		//int idx = mre_index[id];
		delta_22[mre_index[id]] = delta_m_a[id] * (1 + mre[id]) * (1 - mre[id]);
	}*/
	int tid = threadIdx.x;
	int bid = blockIdx.x;
	if(tid<NEU_NUM1 && bid<mre_size){
		__shared__ double mid[1][NEU_NUM1];
		mid[0][tid] = omega1[tid + bid*NEU_NUM1] * delta_f_z[tid];
		__syncthreads();//waiting for all threads
		omega1[tid + bid*NEU_NUM1] = omega1[tid + bid*NEU_NUM1] - LEARN_RATE*(mre[bid]*delta_f_z[tid]);
		int length = NEU_NUM1;
		int offset = (length - 1)/2 + 1;
		while(length >= 2){
			if(tid + offset < length){
				mid[0][tid] = mid[0][tid] + mid[0][tid+offset];
			}
			length = (length - 1)/2 + 1;
			offset = (offset - 1)/2 + 1;
			__syncthreads();
		}

		if(tid < 1)
			delta_22[mre_index[bid]] = mid[0][0] * (1 + mre[bid]) * (1 - mre[bid]);
	}
}

//bacdward convolutional layer
__global__ static void bp_update_kernel(int iter,int i0, double LEARN_RATE, int z, int mre_num,int re_size, int * mre_index, double * delta_22, double * data, double * kernel,double * bias0)
{
	/*int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum =blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;
	if(id < KER_NUM){
		extern __shared__ double train_tmp[];
		copy_data_to_shared(data, train_tmp, x*y*z*i0, x*y*z);
		double * delta_k_w = new double [x*y*P_NUM];
		for(int i=0; i<x*y*P_NUM;i++)
			delta_k_w[i] = 0;

		double mid = 0;
		int i, j, idx, n, head;
		for (i=0; i<mre_num; i++){
			idx = mre_index[i + id*mre_num];
			n = idx % re_size;//对应卷积的第n块数据
			head = x*y*LEAP*n;
			for(j=0; j<x*y*P_NUM; j++){
				delta_k_w[j] = delta_k_w[j] + delta_22[idx] * train_tmp[j+head];
			}
			mid = mid + delta_22[idx];
		
		}

		for(i=0;i<x*y*P_NUM;i++){
			delta_k_w[i] = delta_k_w[i]/mre_num;
			kernel[id*x*y*P_NUM+i] = kernel[id*x*y*P_NUM+i] - LEARN_RATE*delta_k_w[i];
		}
		//double delta_k_b = delta_22[idx];
		bias0[id] = bias0[id] - LEARN_RATE*(mid/mre_num);
		delete [] delta_k_w;
	}*/
	int tid = threadIdx.x;
	int bid = blockIdx.x;
	if(tid < ((NEIGHBOR+1)*P_NUM) && (bid < KER_NUM))
	{
		int head = i0*(NEIGHBOR+1)*z;
		int length = (NEIGHBOR+1)*z;
		int offset = (length - 1)/((NEIGHBOR+1)*P_NUM) + 1;
		__shared__ double train_tmp[1][MAX_MRE];
		copy_data_to_share(data, train_tmp, tid, offset, head, length);
		__syncthreads();
		//extern __shared__ double train_tmp[];
                //copy_data_to_shared(data, train_tmp, x*y*z*i0, x*y*z);
		__shared__ double delta_k_w[1][(NEIGHBOR+1)*P_NUM];
		delta_k_w[0][tid] = 0;

		int idx, n, i, h;
		double mid = 0;
		for(i=0; i<mre_num; i++){
			idx = mre_index[i + bid*mre_num];
			n = idx % re_size;
			h = n*(NEIGHBOR+1)*LEAP;
			delta_k_w[0][tid] = delta_k_w[0][tid] + delta_22[idx] * train_tmp[0][tid + h];
			mid = mid + delta_22[idx];
		}

		delta_k_w[0][tid] = delta_k_w[0][tid]/mre_num;
		kernel[tid + bid*(NEIGHBOR+1)*P_NUM] = kernel[tid + bid*(NEIGHBOR+1)*P_NUM] - LEARN_RATE*delta_k_w[0][tid];
		
		if(tid < 1)
			bias0[bid] = bias0[bid] - LEARN_RATE*(mid/mre_num);
		
	}
}


__global__ static void processing(int iter, double * data, int * train_index, double * processed_data, int x, int y, int z, int train_size)
{
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	int threadNum = blockDim.x * gridDim.x;
	int id = tid + iter * threadNum;

	//int idx = id * (NEIGHBOR+1) * z;//记录processed_data的开始位置
	if (id < train_size){
		int idx = id * (NEIGHBOR+1) * z;
		int i, j;
		for (i=0; i<z; i++){
			for (j=0; j<(NEIGHBOR+1); j++){
				processed_data[idx] = data[train_index[j + id*(NEIGHBOR+1)] + i * x*y];
				idx = idx + 1;	
			}
		}
	}
}

double lossfunction(double * output, double * labels, int idx){
	double l = 0;
	int i;
	for(i=0; i<NEU_NUM2; i++){
		l = l + labels[i + idx*NEU_NUM2] * log(output[i]) + (1 - labels[i + idx*NEU_NUM2])*log(1 - output[i]); 
        //(output[i] - labels[i + idx*NEU_NUM2]) * (output[i] - labels[i + idx*NEU_NUM2]);
	}
	l = -l/NEU_NUM2;
	return l;
}


//calculate accuracy rate
double count_err(double * test_labels, double * output, int test_idx)
{
	double right=0;
	double max =0;
	int idx = 0;
	int i;
	for(i=0; i<NEU_NUM2; i++){
		if(output[i]>max){
			max = output[i];
			idx = i;
		}
	}
	if((idx+1) == int(test_labels[test_idx]))
		right = 1;
	
	return right;
}


void insert_line(double * a, double b){
	for(int i=1; i<VALID_BATCH; i++){
		a[i-1] = a[i];
	}
	a[VALID_BATCH-1] = b;
}

double max(double * a){
	double m=a[0];
	for(int i=1; i<VALID_BATCH; i++){
		if(m<a[i])
			m=a[i];
	}
	return m;
}
double min(double * a){
    double mini = a[0];
    for(int i=1; i<VALID_BATCH; i++){
        if(mini > a[i]){
            mini = a[i];
        }
    }
    return mini;
}
//shuffle
void shuffle(int * data, double * labels, int dim_row, int width){
	int index,  i;
	int temp;
	double tmp;
	srand(time(NULL));
	for(i=0; i<width; i++){
		index=rand()%(width-i) + i;
		if(index != i){
			for(int j=0; j<dim_row; j++){
				temp = data[j + i*dim_row];
				data[j + i*dim_row] = data[j +index*dim_row];
				data[j + index*dim_row] = temp;
			}

			for(int j=0; j<NEU_NUM2; j++){
				tmp = labels[j + i*NEU_NUM2];
				labels[j + i*NEU_NUM2] = labels[j + index*NEU_NUM2];
				labels[j + index*NEU_NUM2] = tmp;
			}
		}
	}
}


double training(double * data, double * labels, int x, int y, int z){
	clock_t start, end;
	start = clock();	
	double * gpu_data;//显存上存储原始数据
	double * gpu_processed_train;//显存上存储处理之后的数据
	double * gpu_processed_test;
	double * gpu_processed_valid;
	int * gpu_train_index;//训练数据的索引
	int * gpu_test_index;
	int * gpu_valid_index;
	double * gpu_processed_labels;
	//double * gpu_test_labels;

	//计算有标签像素的个数
	int data_size = 0;
	int * data_index = new int [x*y];
	for(int i=0; i<x*y; i++){
		if(labels[i] != 0){
			data_index[data_size]=i;
			data_size ++;
		}
	}
	int test_size = (data_size-1)/5 + 1;
	//int valid_size = test_size;
	int train_size = data_size - test_size;
	fprintf(stdout,"train_size:%d  test_size:%d\n",train_size,test_size/*,valid_size*/);
	int * train_index = new int [train_size * (NEIGHBOR + 1)];//9行，x*y列。每列保存一个像素及其邻居的索引位置
	//int * valid_index = new int [valid_size * (NEIGHBOR + 1)];
	int * test_index = new int [test_size * (NEIGHBOR+1)];

	double * processed_labels = new double [train_size * NEU_NUM2]();
	double * test_labels = new double [test_size]();
	//double * valid_labels = new double [valid_size]();
	int tr=0, te=0, va=0;
	for (int i=0; i<data_size; i++){
		if (i%5 != 0 /*&& i%5 != 1*/){
			train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1)] = data_index[i];//当前像素索引
			if(NEIGHBOR == 4)
			{
				train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) - 1] = data_index[i] - 1;
				train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) + 1] = data_index[i] + 1;
				train_index[0 + tr * (NEIGHBOR+1)] = data_index[i] - x;
				train_index[NEIGHBOR + tr * (NEIGHBOR+1)] = data_index[i] + x;
				

				if((data_index[i] % x) == 0){//first row
					train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) - 1] = train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) + 1];
				}
				if((data_index[i] % x) == (x-1)){//last row
					train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) + 1] = train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) - 1];
				}
				if((data_index[i]/x) == 0){//first column
					train_index[0 + tr * (NEIGHBOR+1)] = train_index[NEIGHBOR + tr * (NEIGHBOR+1)];
				}
				if((data_index[i]/x) == (y-1)){//last column
					train_index[NEIGHBOR + tr * (NEIGHBOR+1)] = train_index[0 + tr * (NEIGHBOR+1)];
				}
			}
			if(NEIGHBOR == 8)
			{
				train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) - 1] = data_index[i] - 1;
				train_index[(NEIGHBOR/2) + tr * (NEIGHBOR+1) + 1] = data_index[i] + 1;
				for(int j0=0;j0<3;j0++){
					train_index[j0 + tr * (NEIGHBOR+1)] = data_index[i] - 1 - x + j0;
					train_index[j0+6 + tr * (NEIGHBOR+1)] = data_index[i] - 1 + x + j0;
				}

				if((data_index[i] % x) == 0){//first row
					for (int j=0; j<3; j++)
						train_index[j*3 + tr*(NEIGHBOR+1)] = train_index[j*3+2 + tr*(NEIGHBOR+1)];
				}
				if((data_index[i] % x) == (x-1)){//last row
					for(int j=0;j<3;j++)
							train_index[j*3+2 + tr*(NEIGHBOR+1)] = train_index[j*3 + tr*(NEIGHBOR+1)];
				}
				if((data_index[i]/x) == 0){//first column
					for(int j=0;j<3;j++)
						train_index[j + tr*(NEIGHBOR+1)] = train_index[j+6 + tr*(NEIGHBOR+1)];
				}
				if((data_index[i]/x) == (y-1)){//last column
					for(int j=0;j<3;j++)
						train_index[j+6  + tr*(NEIGHBOR+1)] = train_index[j + tr*(NEIGHBOR+1)];
				}
			}

			int mid = int(labels[data_index[i]])-1 + tr*NEU_NUM2;
			processed_labels[mid] = 1;
			tr = tr + 1;
		}
		if(i%5 == 0){
			test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1)] = data_index[i];//当前像素索引
			if(NEIGHBOR == 4)
			{
				test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) - 1] = data_index[i] - 1;
				test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) + 1] = data_index[i] + 1;
				test_index[0 + te * (NEIGHBOR+1)] = data_index[i] - x;
				test_index[NEIGHBOR+ te * (NEIGHBOR+1)] = data_index[i] + x;

				if((data_index[i] % x) == 0){//first row
					test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) - 1] = test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) + 1];
				}
				if((data_index[i] % x) == (x-1)){//last row
					test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) + 1] = test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) - 1];
				}
				if((data_index[i]/x) == 0){//first column
					test_index[0 + te * (NEIGHBOR+1)] = test_index[NEIGHBOR+ te * (NEIGHBOR+1)];
				}
				if((data_index[i]/x) == (y-1)){//last column
					test_index[NEIGHBOR+ te * (NEIGHBOR+1)] = test_index[0 + te * (NEIGHBOR+1)];
				}
			}
			if(NEIGHBOR == 8)
			{
				test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) - 1] = data_index[i] - 1;
				test_index[(NEIGHBOR/2) + te * (NEIGHBOR+1) + 1] = data_index[i] + 1;
				for(int j0=0;j0<3;j0++){
					test_index[j0 + te * (NEIGHBOR+1)] = data_index[i] - 1 - x + j0;
					test_index[j0+6 + te * (NEIGHBOR+1)] = data_index[i] - 1 + x + j0;
				}

				if((data_index[i] % x) == 0){//first row
					for (int j=0; j<3; j++)
						test_index[j*3 + te*(NEIGHBOR+1)] = test_index[j*3+2 + te*(NEIGHBOR+1)];
				}
				if((data_index[i] % x) == (x-1)){//last row
					for(int j=0;j<3;j++)
						test_index[j*3+2 + te*(NEIGHBOR+1)] = test_index[j*3 + te*(NEIGHBOR+1)];
				}
				if((data_index[i]/x) == 0){//first column
					for(int j=0;j<3;j++)
						test_index[j + te*(NEIGHBOR+1)] = test_index[j+6 + te*(NEIGHBOR+1)];
				}
				if((data_index[i]/x) == (y-1)){//last column
					for(int j=0;j<3;j++)
						test_index[j+6  + te*(NEIGHBOR+1)] = test_index[j + te*(NEIGHBOR+1)];
				}
			}
			test_labels[te] = labels[data_index[i]];
			te = te + 1;
		}
		
	}

	shuffle(train_index, processed_labels, (NEIGHBOR+1), train_size);//打乱训练数据的顺序
	//fprintf(stdout,"train_size:%d\n",train_size);
	//fprintf(stdout,"train_index:%d %d %d %d\ntest_index:%d %d %d %d\nvalid_index:%d %d %d %d\n",train_index[0],train_index[1],train_index[2],train_index[3],test_index[0],test_index[1],test_index[2],test_index[3],valid_index[0],valid_index[1],valid_index[2],valid_index[3]);
	//fprintf(stdout,"train labels:\n");
	//for(int i=0; i<NEU_NUM2; i++){
	//	fprintf(stdout,"%lf ",processed_labels[i]);
	//}
	//fprintf(stdout,"\n");
	//fprintf(stdout,"test label:%lf",test_labels[0]);
	//fprintf(stdout,"valid label:%lf",valid_labels[0]);
	//int * train_index = new int [train_size * (NEIGHBOR + 1)];//train_size列，9行。每行保存一个像素及其邻居的索引位置


	//分配显存，拷贝数据到显存上
	SAFE_CALL(cudaMalloc((void **) &gpu_data, sizeof(double) * x * y * z));
	SAFE_CALL(cudaMemcpy(gpu_data, data, sizeof(double)* x * y * z, cudaMemcpyHostToDevice));

	SAFE_CALL(cudaMalloc((void **) &gpu_train_index, sizeof(int) * train_size * (NEIGHBOR+1)));
	SAFE_CALL(cudaMemcpy(gpu_train_index, train_index, sizeof(int) * train_size * (NEIGHBOR+1), cudaMemcpyHostToDevice));
	SAFE_CALL(cudaMalloc((void **) &gpu_test_index, sizeof(int) * test_size * (NEIGHBOR+1)));
	SAFE_CALL(cudaMemcpy(gpu_test_index, test_index, sizeof(int) * test_size * (NEIGHBOR+1), cudaMemcpyHostToDevice));
	//SAFE_CALL(cudaMalloc((void **) &gpu_valid_index, sizeof(int) * valid_size * (NEIGHBOR+1)));
	//SAFE_CALL(cudaMemcpy(gpu_valid_index, valid_index, sizeof(int) * valid_size * (NEIGHBOR+1), cudaMemcpyHostToDevice));

	//SAFE_CALL(cudaMalloc((void **) &gpu_processed_valid, sizeof(double) * valid_size * (NEIGHBOR+1) * z));
	SAFE_CALL(cudaMalloc((void **) &gpu_processed_test, sizeof(double) * test_size * (NEIGHBOR+1) * z));
	SAFE_CALL(cudaMalloc((void **) &gpu_processed_train, sizeof(double) * train_size * (NEIGHBOR+1) * z));//每一批数据的大小

	int gridsize = 64;
	int blocksize = 1024;
	//int threadNum = gridsize * blocksize; 
	double * processed_train = new double [train_size * (NEIGHBOR+1) * z];
	double * processed_test = new double [test_size * (NEIGHBOR+1) * z];
    //double * processed_valid = new double [valid_size * (NEIGHBOR+1) * z];
	//预处理
	int iter=0;

	processing<<<gridsize,blocksize>>>(iter, gpu_data, gpu_train_index, gpu_processed_train, x, y, z, train_size);
	processing<<<gridsize,blocksize>>>(iter, gpu_data, gpu_test_index, gpu_processed_test, x, y, z, test_size);
	//processing<<<gridsize,blocksize>>>(iter, gpu_data, gpu_valid_index, gpu_processed_valid, x, y, z, valid_size);

	cudaDeviceSynchronize();
	end = clock();
	double tt = double(end - start);
	fprintf(stdout,"Preprocessing Done. (%lfs)\n",tt/CLOCKS_PER_SEC);

	//SAFE_CALL(cudaMemcpy(processed_train, gpu_processed_train, sizeof(double) * train_size * (NEIGHBOR+1) * z, cudaMemcpyDeviceToHost));
	//SAFE_CALL(cudaMemcpy(processed_test, gpu_processed_test, sizeof(double) * test_size * (NEIGHBOR+1) * z, cudaMemcpyDeviceToHost));
    //SAFE_CALL(cudaMemcpy(processed_valid, gpu_processed_valid, sizeof(double) * valid_size * (NEIGHBOR+1) * z, cudaMemcpyDeviceToHost));

	SAFE_CALL(cudaFree(gpu_data));
	SAFE_CALL(cudaFree(gpu_train_index));
	SAFE_CALL(cudaFree(gpu_test_index));
	//SAFE_CALL(cudaFree(gpu_valid_index));
	cudaDeviceSynchronize();

	//fprintf(stdout,"Processed train data:%lf %lf %lf %lf\n",processed_train[0],processed_train[1],processed_train[2],processed_train[3]);
	//fprintf(stdout,"Processed test data:%lf %lf %lf %lf\n",processed_test[0],processed_test[1],processed_test[2],processed_test[3]);
   //fprintf(stdout,"processed valid data:%lf %lf %lf %lf\n",processed_valid[0],processed_valid[1],processed_valid[2],processed_valid[3]);
	
    	//start = clock();
	//前向传播
	double * kernel = new double [(NEIGHBOR+1)*P_NUM*KER_NUM];

	//随机生成kernekl数组
	for(int i=0; i<(NEIGHBOR+1)*P_NUM*KER_NUM; i++){
		kernel[i] = 2*(rand()/(double)(RAND_MAX)) - 1 ;
		kernel[i] = kernel[i]/55;
	}
	//fprintf(stdout,"kernel:%lf %lf %lf %lf\n",kernel[0], kernel[1], kernel[2], kernel[3]);
	
	//计算每次卷积的结果个数
	int re_size = 0;
	for (int i=0; i+P_NUM-1<z; i+=LEAP){
		re_size ++;
	}

	//double * re = new double [re_size * KER_NUM];
	fprintf(stdout,"re_size:%d\n",re_size);

	int mre_num = (re_size-1)/GP_NUM + 1;
	fprintf(stdout,"mre_num:%d\n",mre_num);
	int mre_size = mre_num * KER_NUM;
	int ome_num1 = mre_num * KER_NUM * NEU_NUM1;//第一层网络的输入权重个数
	int ome_num2 = NEU_NUM1 * NEU_NUM2;//输出层的权重个数
	
	double * gpu_kernel;
	double * gpu_bias0;
	double * gpu_re;//存放卷积结果
	double * gpu_mre;//存放maxpooling结果
	int * gpu_mre_index;//存放每组最大值的索引
	double * gpu_omega1;//第一层网络的输入权重
	double * gpu_F1;//第一层神经元的输出
	double * gpu_bias1;
	double * gpu_omega2;
	double * gpu_O2;
	double * gpu_bias2;
	//double * gpu_delta_La;
	double * gpu_delta_Lz;
	double * gpu_delta_fa;
	double * gpu_delta_fz;
	
	double * gpu_delta_22;
	double * delta_22 = new double [re_size*KER_NUM]();

	//复制标签
	SAFE_CALL(cudaMalloc((void**) &gpu_processed_labels, sizeof(double) * train_size * NEU_NUM2));
	SAFE_CALL(cudaMemcpy(gpu_processed_labels,processed_labels,sizeof(double) * train_size * NEU_NUM2,cudaMemcpyHostToDevice));
	//复制随机初始化的kernel数组
	SAFE_CALL(cudaMalloc((void**) &gpu_kernel,sizeof(double) * (NEIGHBOR+1) * P_NUM * KER_NUM));
	SAFE_CALL(cudaMemcpy(gpu_kernel,kernel,sizeof(double) * (NEIGHBOR+1) * P_NUM * KER_NUM,cudaMemcpyHostToDevice));
	//卷积结果存入gpu_re，分配显存
	SAFE_CALL(cudaMalloc((void **) &gpu_re,sizeof(double) * re_size * KER_NUM));
	//输出层偏导数
	//SAFE_CALL(cudaMalloc((void **) &gpu_delta_La, sizeof(double) * NEU_NUM2));
	SAFE_CALL(cudaMalloc((void **) &gpu_delta_Lz, sizeof(double) * NEU_NUM2));
	//全连接层偏导数
	SAFE_CALL(cudaMalloc((void **) &gpu_delta_fa, sizeof(double) * NEU_NUM1));
	SAFE_CALL(cudaMalloc((void **) &gpu_delta_fz, sizeof(double) * NEU_NUM1));
	//maxpooling
	SAFE_CALL(cudaMalloc((void **) &gpu_delta_22,sizeof(double) * re_size * KER_NUM));
	SAFE_CALL(cudaMemcpy(gpu_delta_22, delta_22, sizeof(double) * re_size * KER_NUM, cudaMemcpyHostToDevice));
	//SAFE_CALL(cudaMalloc((void **) &gpu_delta_kw, sizeof(double) * (NEIGHBOR+1) *P_NUM));

	double * omega1 = new double [ome_num1];
	double * omega2 = new double [ome_num2];
	double * bias0 = new double [KER_NUM];
	double * bias1 = new double [NEU_NUM1];
	double * bias2 = new double [NEU_NUM2];

	//随机生成Omega1
	for(int i=0; i<ome_num1; i++){
		omega1[i] = 2 * (rand()/(double)(RAND_MAX)) - 1;
		omega1[i] = omega1[i]/55;
	        if(omega1[i] == 0)
			omega1[i] = 0.01;
	}
	//随机生成bias0
	for(int i=0; i<KER_NUM; i++){
		bias0[i] = 2*(rand()/(double)(RAND_MAX)) - 1;
		bias0[i] = bias0[i]/55;
	}
	//随机生成bias1
	for(int i=0; i<NEU_NUM1; i++){
		bias1[i] = 2*(rand()/(double)(RAND_MAX)) - 1;
		bias1[i] = bias1[i]/55;
	}

	//随机生成Omega2
	for(int i=0; i<ome_num2; i++){
		omega2[i] = 2 * (rand()/(double)(RAND_MAX)) - 1;
		omega2[i] = omega2[i]/55;
		if(omega2[i] ==0)
			omega2[i] = 0.01;
	}
	//fprintf(stdout, "Bias1: %lf %lf %lf\n",bias1[0],bias1[1],bias1[2]);
	//随机生成bias2
	for(int i=0; i<NEU_NUM2; i++){
		bias2[i] = 2*(rand()/(double)(RAND_MAX)) - 1;
		bias2[i] = bias2[i]/55;
	}
	//fprintf(stdout, "Bias2: %lf %lf %lf\n",bias2[0],bias2[1],bias2[2]);

	SAFE_CALL(cudaMalloc((void **) &gpu_mre, sizeof(double) * mre_num * KER_NUM));//maxpooling结果存入gpu_mre，分配显存
	SAFE_CALL(cudaMalloc((void **) &gpu_mre_index, sizeof(int) * mre_num * KER_NUM));//为maxpooling的最大值索引分配显存
	SAFE_CALL(cudaMalloc((void **) &gpu_omega1, sizeof(double) * ome_num1));//第一层网络的输入权重，分配显存
	SAFE_CALL(cudaMalloc((void **) &gpu_omega2, sizeof(double) * ome_num2));//输出层的权重，分配显存
	SAFE_CALL(cudaMalloc((void **) &gpu_F1, sizeof(double) * NEU_NUM1));//第一层网络的输出，分配显存
	SAFE_CALL(cudaMalloc((void **) &gpu_O2, sizeof(double) * NEU_NUM2));//输出层的结果
	SAFE_CALL(cudaMalloc((void **) &gpu_bias0, sizeof(double) * KER_NUM));//卷积层偏置值
	SAFE_CALL(cudaMalloc((void **) &gpu_bias1, sizeof(double) * NEU_NUM1));//全连接层偏置值
	SAFE_CALL(cudaMalloc((void **) &gpu_bias2, sizeof(double) * NEU_NUM2));//输出层偏置
	SAFE_CALL(cudaMemcpy(gpu_omega1, omega1, sizeof(double) * ome_num1, cudaMemcpyHostToDevice));//复制初始权重到GPU端
	SAFE_CALL(cudaMemcpy(gpu_omega2, omega2, sizeof(double) * ome_num2, cudaMemcpyHostToDevice));
	SAFE_CALL(cudaMemcpy(gpu_bias0, bias0, sizeof(double) * KER_NUM, cudaMemcpyHostToDevice));
	SAFE_CALL(cudaMemcpy(gpu_bias1, bias1, sizeof(double) * NEU_NUM1, cudaMemcpyHostToDevice));//复制偏置值到显存
	SAFE_CALL(cudaMemcpy(gpu_bias2, bias2, sizeof(double) * NEU_NUM2, cudaMemcpyHostToDevice));

	//double * delta_22 = new double [re_size * KER_NUM];//CPU端存放maxpooling结果
	//double * bias0 = new double [KER_NUM];//CPU端存放第一层网络输出结果
	double * O2 = new double [NEU_NUM2];//CPU端存放输出层的结果
	//double * lz = new double [NEU_NUM2];
	double loss;
    	double * logloss = new double [300]();
	double * correct_rate = new double [VALID_BATCH];
    	for(int i=0; i<VALID_BATCH; i++){
        	correct_rate[i] = 1;
    	}

    	double cur_min = 1;
	double single_loss = 0;
	int count=1;
	start = clock();
	iter = 0;
	for(int j=0; j<300; j++){
		//if (j % 100 == 0)
		//	fprintf(stdout,"The %dth iteration.\n",j);
		loss = 0;
		for(int i0=0; i0<train_size; i0++){

			//卷积，每个线程负责一个卷积核和训练数据的卷积
			convol<<<KER_NUM,re_size>>>(iter,i0,gpu_processed_train,gpu_kernel,gpu_re,gpu_bias0,z,re_size);
			//if(i0 == 1)	fprintf(stdout,"Convol time:%lf\n",convol_time);
			cudaDeviceSynchronize();

			//下采样，maxpooling方法，每个线程负责re的一列
			maxpooling<<<KER_NUM,mre_num>>>(iter,gpu_re,gpu_mre,gpu_mre_index,re_size,mre_num);
			cudaDeviceSynchronize();

			//全连接层
			fullconnect<<<NEU_NUM1,mre_size>>>(iter,gpu_mre,gpu_omega1,gpu_bias1,gpu_F1,mre_size);
			cudaDeviceSynchronize();

			//输出层
			output<<<1,NEU_NUM2>>>(iter,gpu_F1,gpu_omega2,gpu_bias2,gpu_O2);
			cudaDeviceSynchronize();

			SAFE_CALL(cudaMemcpy(O2, gpu_O2, sizeof(double) * NEU_NUM2, cudaMemcpyDeviceToHost));
			cudaDeviceSynchronize();
			single_loss = lossfunction(O2, processed_labels, i0);
			loss = loss + single_loss;
			//fprintf(stdout,"Iteration %d, echo %d, loss = %lf\n",j,i0,single_loss);
			//if(single_loss < MIN_ERR)
			//	break;

			//反向传播，输出层
			bp_output<<<1,NEU_NUM2>>>(iter,i0,LEARN_RATE,gpu_processed_labels,gpu_O2,gpu_bias2,gpu_delta_Lz);
			cudaDeviceSynchronize();

            		//反向传播，全连接层
			bp_fullconnect<<<NEU_NUM1,NEU_NUM2>>>(iter,LEARN_RATE,gpu_omega2,gpu_bias1,gpu_F1,gpu_delta_Lz,gpu_delta_fa,gpu_delta_fz);
			cudaDeviceSynchronize();
            		//反向传播，maxpooling层
			bp_maxpooling<<<mre_size,NEU_NUM1>>>(iter,mre_size,LEARN_RATE,gpu_mre_index,gpu_omega1,gpu_mre,gpu_delta_fa,gpu_delta_fz,gpu_delta_22);
			cudaDeviceSynchronize();
            		//反向传播，map到卷积层
			bp_update_kernel<<<KER_NUM,(NEIGHBOR+1)*P_NUM>>>(iter,i0,LEARN_RATE,z,mre_num,re_size,gpu_mre_index,gpu_delta_22,gpu_processed_train,gpu_kernel,gpu_bias0);
			cudaDeviceSynchronize();
		}

		//测试验证集上的准确率
		double single_rate = loss/train_size;
        	logloss[j] = single_rate;
		if(single_rate < MIN_ERR)
			break;
		//for(int i1=0; i1<valid_size; i1++){
		//	iter = 0;
		//	convol<<<1,KER_NUM,(NEIGHBOR+1)*z*sizeof(double)>>>(iter,i1,gpu_processed_valid,gpu_kernel,gpu_re,gpu_bias0,3,3,z,re_size);

		//	maxpooling<<<1,KER_NUM>>>(iter,gpu_re,gpu_mre,gpu_mre_index,re_size,mre_num);
			
		//	fullconnect<<<1,NEU_NUM1,mre_size * sizeof(double)>>>(iter,gpu_mre,gpu_omega1,gpu_bias1,gpu_F1,mre_size);
			
		//	output<<<1,NEU_NUM2>>>(iter,gpu_F1,gpu_omega2,gpu_bias2,gpu_O2);
		//	cudaDeviceSynchronize();
			
		//	SAFE_CALL(cudaMemcpy(O2, gpu_O2, sizeof(double) * NEU_NUM2, cudaMemcpyDeviceToHost));
		//	cudaDeviceSynchronize();

		//	double right = count_err(valid_labels, O2, i1);
		//	single_rate = single_rate + right;
		//}
		fprintf(stdout,"Iteration %d,	loss = %lf;\n",j+1,single_rate);
		insert_line(correct_rate,single_rate);//将当前的正确率插入队列
		double new_min = min(correct_rate);
        	if(cur_min > new_min){
            		cur_min = new_min;
		     	count = 1;
        	}
        	else{
            		count++;
        	}
        	if(count >= VALID_BATCH) {
            		LEARN_RATE = LEARN_RATE * 0.9;
            		fprintf(stdout,"LEARN_RATE:%lf\n",LEARN_RATE);
            		count = 1;
            		cur_min = new_min;
        	}		
	}

	/*fprintf(stdout,"Convol time:%lfs\n",convol_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Maxpooling time:%lfs\n",maxp_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Fullconnection time:%lfs\n",fullcon_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Output time:%lfs\n",out_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Back convol time:%lfs\n",bp_convol_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Back maxpooling time:%lfs\n",bp_maxp_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Back fullconnection time:%lfs\n",bp_fullcon_time/CLOCKS_PER_SEC);
	fprintf(stdout,"Back output time:%lfs\n",bp_out_time/CLOCKS_PER_SEC);*/
	fprintf(stdout,"Training completed!\n");
	end = clock();
	tt = double(end - start);
	fprintf(stdout,"Using time of training:%lfs\n",tt/CLOCKS_PER_SEC);

	start = clock();
	//cudaDeviceSynchronize();
	SAFE_CALL(cudaMemcpy(kernel, gpu_kernel, sizeof(double) * (NEIGHBOR+1) * P_NUM * KER_NUM, cudaMemcpyDeviceToHost));
	SAFE_CALL(cudaMemcpy(bias0, gpu_bias0, sizeof(double) * KER_NUM, cudaMemcpyDeviceToHost));
	SAFE_CALL(cudaMemcpy(bias1, gpu_bias1, sizeof(double) * NEU_NUM1, cudaMemcpyDeviceToHost));
	SAFE_CALL(cudaMemcpy(bias2, gpu_bias2, sizeof(double) * NEU_NUM2, cudaMemcpyDeviceToHost));
	SAFE_CALL(cudaMemcpy(omega1, gpu_omega1, sizeof(double) * ome_num1, cudaMemcpyDeviceToHost));
	SAFE_CALL(cudaMemcpy(omega2, gpu_omega2, sizeof(double) * ome_num2, cudaMemcpyDeviceToHost));
	cudaDeviceSynchronize();
	//fprintf(stdout,"kernel:%lf %lf %lf %lf\n",kernel[0], kernel[1], kernel[2], kernel[3]);

	//将训练完的参数写入mat文件
	MATFile * pmatFile;
	pmatFile = matOpen("model.mat","w");
	mxArray * m1 = mxCreateDoubleMatrix((NEIGHBOR+1)*P_NUM,KER_NUM,mxREAL);
	memcpy((void *)mxGetPr(m1), (void *)kernel, sizeof(double) * (NEIGHBOR+1) * P_NUM * KER_NUM);
	matPutVariable(pmatFile, "kernel", m1);

	mxArray * m2 = mxCreateDoubleMatrix(KER_NUM,1,mxREAL);
	memcpy((void *)mxGetPr(m2), (void *)bias0, sizeof(double) * KER_NUM);
	matPutVariable(pmatFile, "bias0", m2);

	mxArray * m3 = mxCreateDoubleMatrix(NEU_NUM1,mre_size,mxREAL);
	memcpy((void *)mxGetPr(m3), (void *)omega1, sizeof(double) * ome_num1);
	matPutVariable(pmatFile, "omega1", m3);

	mxArray * m4 = mxCreateDoubleMatrix(NEU_NUM1,1,mxREAL);
       	memcpy((void *)mxGetPr(m4), (void *)bias1, sizeof(double) * NEU_NUM1);
	matPutVariable(pmatFile, "bias1", m4);

	mxArray * m5 = mxCreateDoubleMatrix(NEU_NUM2,NEU_NUM1,mxREAL);
	memcpy((void *)mxGetPr(m5), (void *)omega2, sizeof(double) * ome_num2);
	matPutVariable(pmatFile, "omega2", m5);

	mxArray * m6 = mxCreateDoubleMatrix(NEU_NUM2,1,mxREAL);
	memcpy((void *)mxGetPr(m6), (void *)bias2, sizeof(double) * NEU_NUM2);
	matPutVariable(pmatFile, "bias2", m6);

    	mxArray * m7 = mxCreateDoubleMatrix(300,1,mxREAL);
    	memcpy((void *)mxGetPr(m7), (void *)logloss, sizeof(double) * 300);
    	matPutVariable(pmatFile, "loss", m7);

	matClose(pmatFile);
	
	//test
	double right = 0;
	double count0 = 0;
	for (int i1=0; i1<test_size; i1++){
		int iter = 0;
		convol<<<KER_NUM,re_size/*,(NEIGHBOR+1)*z*sizeof(double)*/>>>(iter,i1,gpu_processed_test,gpu_kernel,gpu_re,gpu_bias0,z,re_size);
		cudaDeviceSynchronize();

		maxpooling<<<KER_NUM,mre_num>>>(iter,gpu_re,gpu_mre,gpu_mre_index,re_size,mre_num);
		cudaDeviceSynchronize();

		fullconnect<<<NEU_NUM1,mre_size/*,mre_size * sizeof(double)*/>>>(iter,gpu_mre,gpu_omega1,gpu_bias1,gpu_F1,mre_size);
		cudaDeviceSynchronize();

		output<<<1,NEU_NUM2>>>(iter,gpu_F1,gpu_omega2,gpu_bias2,gpu_O2);
		cudaDeviceSynchronize();

		SAFE_CALL(cudaMemcpy(O2, gpu_O2, sizeof(double) * NEU_NUM2, cudaMemcpyDeviceToHost));
		cudaDeviceSynchronize();

		//fprintf(stdout,"\n");
		right = count_err(test_labels, O2, i1);
		count0 = count0 + right;
	}
	end = clock();
	tt = double(end - start);
	fprintf(stdout,"Using time of testing:%lfs\n",tt/CLOCKS_PER_SEC);
	return count0/test_size;
}

//主函数
int main(int argc, char * argv[])
{
  	if(!InitCUDA()){
		return 0;
	}
	printf("CUDA initialized.\n");

	clock_t start,end;

	double *trainset,*trainlabels;
	if(argc!=2){
		fprintf(stderr, "4 input arguments required!");
	}
	MATFile * datamat = matOpen(argv[1], "r");
	mxArray * train = matGetVariable(datamat,"DataSet");
	mxArray * labels = matGetVariable(datamat,"labels");

	trainset = (double*)mxGetData(train);
	trainlabels = (double*)mxGetData(labels);

	const mwSize  * dim;
	dim = mxGetDimensions(train);//获取trainset每维的元素个数

	start = clock();
	double correct = training(trainset, trainlabels, dim[0], dim[1], dim[2]);
	end = clock();
    fprintf(stdout,"Correct Rate:%lf(300 iterations, train size, train:test=8:2, 0.008->0.001)\n",correct);
	double usetime = double(end - start);
	fprintf(stdout, "Using time of the whole procedure:%lfs\n",usetime/CLOCKS_PER_SEC);
	return 0;
}
