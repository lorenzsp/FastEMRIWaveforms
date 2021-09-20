// Interpolate and sum modes for an EMRI waveform

// Copyright (C) 2020 Michael L. Katz, Alvin J.K. Chua, Niels Warburton, Scott A. Hughes
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

#include "global.h"
#include "interpolate.hh"

// adjust imports based on CUDA or not
#ifdef __CUDACC__
#include "cusparse.h"
#else
#include "lapacke.h"
#endif
#ifdef __USE_OMP__
#include "omp.h"
#endif


#ifdef __CUDACC__
#define MAX_MODES_BLOCK 450
#else
#define MAX_MODES_BLOCK 5000
#endif

#define NUM_TERMS 4

// fills the coefficients of the cubic spline
// according to scipy Cubic Spline
CUDA_CALLABLE_MEMBER
void fill_coefficients(int i, int length, double *dydx, double dx, double *y, double *coeff1, double *coeff2, double *coeff3)
{
  double slope, t, dydx_i;

  slope = (y[i+1] - y[i])/dx;

  dydx_i = dydx[i];

  t = (dydx_i + dydx[i+1] - 2*slope)/dx;

  coeff1[i] = dydx_i;
  coeff2[i] = (slope - dydx_i) / dx - t;
  coeff3[i] = t/dx;
}

// fills the banded matrix that will be solved for spline coefficients
// according to scipy Cubic Spline
  // this performs a not-a-knot spline
CUDA_CALLABLE_MEMBER
void prep_splines(int i, int length, double *b, double *ud, double *diag, double *ld, double *x, double *y)
{
    double dx1, dx2, d, slope1, slope2;

    // this performs a not-a-knot spline
    // need to adjust for ends of the splines
    if (i == length - 1)
    {
        dx1 = x[length - 2] - x[length - 3];
        dx2 = x[length - 1] - x[length - 2];
        d = x[length - 1] - x[length - 3];

        slope1 = (y[length - 2] - y[length - 3])/dx1;
        slope2 = (y[length - 1] - y[length - 2])/dx2;

        b[length - 1] = ((dx2*dx2*slope1 +
                                 (2*d + dx2)*dx1*slope2) / d);
        diag[length - 1] = dx1;
        ld[length - 1] = d;
        ud[length - 1] = 0.0;

    }

    else if (i == 0)
    {
        dx1 = x[1] - x[0];
        dx2 = x[2] - x[1];
        d = x[2] - x[0];

        slope1 = (y[1] - y[0])/dx1;
        slope2 = (y[2] - y[1])/dx2;

        b[0] = ((dx1 + 2*d) * dx2 * slope1 +
                          dx1*dx1 * slope2) / d;
        diag[0] = dx2;
        ud[0] = d;
        ld[0] = 0.0;

    }

    else
    {
        dx1 = x[i] - x[i-1];
        dx2 = x[i+1] - x[i];

        slope1 = (y[i] - y[i-1])/dx1;
        slope2 = (y[i+1] - y[i])/dx2;

        b[i] = 3.0* (dx2*slope1 + dx1*slope2);
        diag[i] = 2*(dx1 + dx2);
        ud[i] = dx1;
        ld[i] = dx2;
    }
}


// wrapper to fill the banded matrix that will be solved for spline coefficients
// according to scipy Cubic Spline
CUDA_KERNEL
void fill_B(double *t_arr, double *y_all, double *B, double *upper_diag, double *diag, double *lower_diag,
                      int ninterps, int length)
{

    #ifdef __CUDACC__

    int start1 = blockIdx.y*blockDim.y + threadIdx.y;
    int end1 = ninterps;
    int diff1 = blockDim.y*gridDim.y;

    int start2 = blockIdx.x*blockDim.x + threadIdx.x;
    int end2 = length;
    int diff2 = blockDim.x * gridDim.x;
    #else

    int start1 = 0;
    int end1 = ninterps;
    int diff1 = 1;

    int start2 = 0;
    int end2 = length;
    int diff2 = 1;

    #pragma omp parallel for
    #endif
    for (int interp_i= start1;
         interp_i<end1; // 2 for re and im
         interp_i+= diff1)
         {

       for (int i = start2;
            i < end2;
            i += diff2)
            {

                int lead_ind = interp_i*length;
                prep_splines(i, length, &B[lead_ind], &upper_diag[lead_ind], &diag[lead_ind], &lower_diag[lead_ind], &t_arr[lead_ind], &y_all[interp_i*length]);
            }
        }
}


// wrapper to set spline coefficients
// according to scipy Cubic Spline
CUDA_KERNEL
void set_spline_constants(double *t_arr, double *interp_array, double *B,
                      int ninterps, int length)
{

    double dt;
    InterpContainer mode_vals;

    #ifdef __CUDACC__
    int start1 = blockIdx.y*blockDim.y + threadIdx.y;
    int end1 = ninterps;
    int diff1 = blockDim.y*gridDim.y;

    int start2 = blockIdx.x*blockDim.x + threadIdx.x;
    int end2 = length - 1;
    int diff2 = blockDim.x * gridDim.x;
    #else

    int start1 = 0;
    int end1 = ninterps;
    int diff1 = 1;

    int start2 = 0;
    int end2 = length - 1;
    int diff2 = 1;

    #pragma omp parallel for
    #endif

    for (int interp_i= start1;
         interp_i<end1; // 2 for re and im
         interp_i+= diff1)
         {

       for (int i = start2;
            i < end2;
            i += diff2)
            {

              dt = t_arr[interp_i * length + i + 1] - t_arr[interp_i * length + i];

              int lead_ind = interp_i*length;
              fill_coefficients(i, length, &B[lead_ind], dt,
                                &interp_array[0 * ninterps * length + lead_ind],
                                &interp_array[1 * ninterps * length + lead_ind],
                                &interp_array[2 * ninterps * length + lead_ind],
                                &interp_array[3 * ninterps * length + lead_ind]);

             }
        }
}


// wrapper for cusparse solution for coefficients from banded matrix
void fit_wrap(int m, int n, double *a, double *b, double *c, double *d_in)
{
    #ifdef __CUDACC__
    size_t bufferSizeInBytes;

    cusparseHandle_t handle;
    void *pBuffer;

    CUSPARSE_CALL(cusparseCreate(&handle));
    CUSPARSE_CALL( cusparseDgtsv2StridedBatch_bufferSizeExt(handle, m, a, b, c, d_in, n, m, &bufferSizeInBytes));
    gpuErrchk(cudaMalloc(&pBuffer, bufferSizeInBytes));

    // solve banded matrix problem
    CUSPARSE_CALL(cusparseDgtsv2StridedBatch(handle,
                                              m,
                                              a, // dl
                                              b, //diag
                                              c, // du
                                              d_in,
                                              n,
                                              m,
                                              pBuffer));

  CUSPARSE_CALL(cusparseDestroy(handle));
  gpuErrchk(cudaFree(pBuffer));

  #else

    // use lapack on CPU
    #ifdef __USE_OMP__
    #pragma omp parallel for
    #endif
    for (int j = 0;
         j < n;
         j += 1)
         {
               int info = LAPACKE_dgtsv(LAPACK_COL_MAJOR, m, 1, &a[j*m + 1], &b[j*m], &c[j*m], &d_in[j*m], m);
         }

  #endif
}

// interpolate many y arrays (interp_array) with a singular x array (t_arr)
// see python documentation for shape necessary for this to be done
void interpolate_arrays(double *t_arr, double *interp_array, int ninterps, int length, double *B, double *upper_diag, double *diag, double *lower_diag)
{

    // need to fill the banded matrix
    // solve it
    // fill the coefficient arrays
    // do that below on GPU or CPU

  #ifdef __CUDACC__
  int NUM_THREADS = 64;
  int num_blocks = std::ceil((length + NUM_THREADS -1)/NUM_THREADS);
  dim3 gridDim(num_blocks); //, num_teuk_modes);
  fill_B<<<gridDim, NUM_THREADS>>>(t_arr, interp_array, B, upper_diag, diag, lower_diag, ninterps, length);
  cudaDeviceSynchronize();
  gpuErrchk(cudaGetLastError());

  fit_wrap(length, ninterps, lower_diag, diag, upper_diag, B);

  set_spline_constants<<<gridDim, NUM_THREADS>>>(t_arr, interp_array, B,
                                 ninterps, length);
  cudaDeviceSynchronize();
  gpuErrchk(cudaGetLastError());

  #else

  fill_B(t_arr, interp_array, B, upper_diag, diag, lower_diag, ninterps, length);

  fit_wrap(length, ninterps, lower_diag, diag, upper_diag, B);

  set_spline_constants(t_arr, interp_array, B,
                                 ninterps, length);

  #endif

}

/////////////////////////////////
/////////
/////////  MODE SUMMATION
/////////
/////////////////////////////////


// build mode value with specific phase and amplitude values; mode indexes; and spherical harmonics
CUDA_CALLABLE_MEMBER
cmplx get_mode_value(cmplx teuk_mode, fod Phi_phi, fod Phi_r, int m, int n, cmplx Ylm){
    cmplx minus_I(0.0, -1.0);
    fod phase = m*Phi_phi + n*Phi_r;
    cmplx out = (teuk_mode*Ylm)*gcmplx::exp(minus_I*phase);
    return out;
}

// Add functionality for proper summation in the kernel
#ifdef __CUDACC__
__device__ double atomicAddDouble(double* address, double val)
{
    unsigned long long* address_as_ull =
                              (unsigned long long*)address;
    unsigned long long old = *address_as_ull, assumed;

    do {
        assumed = old;
        old = atomicCAS(address_as_ull, assumed,
                        __double_as_longlong(val +
                               __longlong_as_double(assumed)));

    // Note: uses integer comparison to avoid hang in case of NaN (since NaN != NaN)
    } while (assumed != old);

    return __longlong_as_double(old);
}

// Add functionality for proper summation in the kernel
__device__ void atomicAddComplex(cmplx* a, cmplx b){
  //transform the addresses of real and imag. parts to double pointers
  double *x = (double*)a;
  double *y = x+1;
  //use atomicAdd for double variables
  atomicAddDouble(x, b.real());
  atomicAddDouble(y, b.imag());
}

#endif


// make a waveform in parallel
// this uses an efficient summation by loading mode information into shared memory
// shared memory is leveraged heavily
CUDA_KERNEL
void make_waveform(cmplx *waveform,
             double *interp_array,
              int *m_arr_in, int *n_arr_in, int num_teuk_modes, cmplx *Ylms_in,
              double delta_t, double start_t, int old_ind, int start_ind, int end_ind, int init_length){

    int num_pars = 2;
    cmplx trans(0.0, 0.0);
    cmplx trans2(0.0, 0.0);

    cmplx complexI(0.0, 1.0);
    cmplx mode_val;
    cmplx trans_plus_m(0.0, 0.0), trans_minus_m(0.0, 0.0);
    double Phi_phi_i, Phi_r_i, t, x, x2, x3, mode_val_re, mode_val_im;
    int lm_i, num_teuk_here;
    double re_y, re_c1, re_c2, re_c3, im_y, im_c1, im_c2, im_c3;
     CUDA_SHARED double pp_y, pp_c1, pp_c2, pp_c3, pr_y, pr_c1, pr_c2, pr_c3;

     // declare all the shared memory
     // MAX_MODES_BLOCK is fixed based on shared memory
     CUDA_SHARED cmplx Ylms[2*MAX_MODES_BLOCK];
     CUDA_SHARED double mode_re_y[MAX_MODES_BLOCK];
     CUDA_SHARED double mode_re_c1[MAX_MODES_BLOCK];
     CUDA_SHARED double mode_re_c2[MAX_MODES_BLOCK];
     CUDA_SHARED double mode_re_c3[MAX_MODES_BLOCK];

     CUDA_SHARED double mode_im_y[MAX_MODES_BLOCK];
     CUDA_SHARED double mode_im_c1[MAX_MODES_BLOCK];
     CUDA_SHARED double mode_im_c2[MAX_MODES_BLOCK];
     CUDA_SHARED double mode_im_c3[MAX_MODES_BLOCK];

     CUDA_SHARED int m_arr[MAX_MODES_BLOCK];
     CUDA_SHARED int n_arr[MAX_MODES_BLOCK];

     // number of splines
     int num_base = init_length * (2 * num_teuk_modes + num_pars);

     CUDA_SYNC_THREADS;

     #ifdef __CUDACC__

     if ((threadIdx.x == 0)){
     #else
     if (true){
     #endif

        // fill phase values. These will be same for all modes
         int ind_Phi_phi = old_ind*(2*num_teuk_modes+num_pars) + num_teuk_modes*2 + 0;
         int ind_Phi_r = old_ind*(2*num_teuk_modes+num_pars) + num_teuk_modes*2 + 1;

         pp_y = interp_array[0 * num_base + ind_Phi_phi]; pp_c1 = interp_array[1 * num_base + ind_Phi_phi];
         pp_c2= interp_array[2 * num_base + ind_Phi_phi];  pp_c3 = interp_array[3 * num_base + ind_Phi_phi];

         pr_y = interp_array[0 * num_base + ind_Phi_r]; pr_c1 = interp_array[1 * num_base + ind_Phi_r];
         pr_c2= interp_array[2 * num_base + ind_Phi_r];  pr_c3 = interp_array[3 * num_base + ind_Phi_r];
     }

     CUDA_SYNC_THREADS;

     int m, n, actual_mode_index;
     cmplx Ylm_plus_m, Ylm_minus_m;

     int num_breaks = (num_teuk_modes / MAX_MODES_BLOCK) + 1;

     // this does a special loop to fill mode information into shared memory in chunks
     for (int block_y=0; block_y<num_breaks; block_y+=1){
    num_teuk_here = (((block_y + 1)*MAX_MODES_BLOCK) <= num_teuk_modes) ? MAX_MODES_BLOCK : num_teuk_modes - (block_y*MAX_MODES_BLOCK);

    int init_ind = block_y*MAX_MODES_BLOCK;


    #ifdef __CUDACC__

    int start = threadIdx.x;
    int end = num_teuk_here;
    int diff = blockDim.x;

    #else

    int start = 0;
    int end = num_teuk_here;
    int diff = 1;
    #ifdef __USE_OMP__
    #pragma omp parallel for
    #endif // __USE_OMP__
    #endif
    for (int i=start; i<end; i+=diff)
    {

        // fill mode values and Ylms
        int ind_re = old_ind*(2*num_teuk_modes+num_pars) + (init_ind + i);
        int ind_im = old_ind*(2*num_teuk_modes+num_pars)  + num_teuk_modes + (init_ind + i);
        mode_re_y[i] = interp_array[0 * num_base + ind_re]; mode_re_c1[i] = interp_array[1 * num_base + ind_re];
        mode_re_c2[i] = interp_array[2 * num_base + ind_re]; mode_re_c3[i] = interp_array[3 * num_base + ind_re];

        mode_im_y[i] = interp_array[0 * num_base + ind_im]; mode_im_c1[i] = interp_array[1 * num_base + ind_im];
        mode_im_c2[i] = interp_array[2 * num_base + ind_im]; mode_im_c3[i] = interp_array[3 * num_base + ind_im];

        m_arr[i] = m_arr_in[init_ind + i];
        n_arr[i] = n_arr_in[init_ind + i];
        Ylms[2*i] = Ylms_in[(init_ind + i)];
        Ylms[2*i + 1] = Ylms_in[num_teuk_modes + (init_ind + i)];
    }

    CUDA_SYNC_THREADS;

    #ifdef __CUDACC__

    start = start_ind + blockIdx.x * blockDim.x + threadIdx.x;
    end = end_ind;
    diff = blockDim.x * gridDim.x;

    #else

    start = start_ind;
    end = end_ind;
    diff = 1;

    #endif
    #ifdef __CUDACC__
    #else
    #ifdef __USE_OMP__
    #pragma omp parallel for
    #endif // __USE_OMP__
    #endif // __CUDACC__

    // start and end is the start and end of points in this interpolation window
    for (int i = start;
         i < end;
         i += diff){

     trans2 = 0.0 + 0.0*complexI;

     trans = 0.0 + 0.0*complexI;

     // determine interpolation information
     t = delta_t*i;
      x = t - start_t;
      x2 = x*x;
      x3 = x*x2;

      // get phases at this timestep
      Phi_phi_i = pp_y + pp_c1*x + pp_c2*x2  + pp_c3*x3;
      Phi_r_i = pr_y + pr_c1*x + pr_c2*x2  + pr_c3*x3;

      // calculate all modes at this timestep
        for (int j=0; j<num_teuk_here; j+=1){

            Ylm_plus_m = Ylms[2*j];

             m = m_arr[j];
             n = n_arr[j];

            mode_val_re =  mode_re_y[j] + mode_re_c1[j]*x + mode_re_c2[j]*x2  + mode_re_c3[j]*x3;
            mode_val_im = mode_im_y[j] + mode_im_c1[j]*x + mode_im_c2[j]*x2  + mode_im_c3[j]*x3;
            mode_val = mode_val_re + complexI*mode_val_im;

                trans_plus_m = get_mode_value(mode_val, Phi_phi_i, Phi_r_i, m, n, Ylm_plus_m);

                // minus m if m > 0
                // mode values for +/- m are taking care of when applying
                //specific mode selection by setting ylms to zero for the opposites
                if (m != 0)
                {

                    Ylm_minus_m = Ylms[2*j + 1];
                    trans_minus_m = get_mode_value(gcmplx::conj(mode_val), Phi_phi_i, Phi_r_i, -m, -n, Ylm_minus_m);

                } else trans_minus_m = 0.0 + 0.0*complexI;

                trans = trans + trans_minus_m + trans_plus_m;
        }

        // fill waveform
        #ifdef __CUDACC__
        atomicAddComplex(&waveform[i], trans);
        #else
        waveform[i] += trans;
        #endif
    }
    CUDA_SYNC_THREADS;
}
}


// with uneven spacing in t in the sparse arrays, need to determine which timesteps the dense arrays fall into
// for interpolation
// effectively the boundaries and length of each interpolation segment of the dense array in the sparse array
void find_start_inds(int start_inds[], int unit_length[], double *t_arr, double delta_t, int *length, int new_length)
{

    double T = (new_length - 1) * delta_t;
  start_inds[0] = 0;
  int i = 1;
  for (i = 1;
       i < *length;
       i += 1){

          double t = t_arr[i];

          // adjust for waveforms that hit the end of the trajectory
          if (t < T){
              start_inds[i] = (int)std::ceil(t/delta_t);
              unit_length[i-1] = start_inds[i] - start_inds[i-1];
          } else {
            start_inds[i] = new_length;
            unit_length[i-1] = new_length - start_inds[i-1];
            break;
        }

      }

  // fixes for not using certain segments for the interpolation
  *length = i + 1;
}

// function for building interpolated EMRI waveform from python
void get_waveform(cmplx *d_waveform, double *interp_array,
              int *d_m, int *d_n, int init_len, int out_len, int num_teuk_modes, cmplx *d_Ylms,
              double delta_t, double *h_t){

    // arrays for determining spline windows for new arrays
    int start_inds[init_len];
    int unit_length[init_len-1];

    int number_of_old_spline_points = init_len;

    // find the spline window information based on equally spaced new array
    find_start_inds(start_inds, unit_length, h_t, delta_t, &number_of_old_spline_points, out_len);

    #ifdef __CUDACC__

    // prepare streams for CUDA
    int NUM_THREADS = 256;
    cudaStream_t streams[number_of_old_spline_points-1];
    int num_breaks = num_teuk_modes/MAX_MODES_BLOCK;

    #endif

    #ifdef __USE_OMP__
    #pragma omp parallel for
    #endif
    for (int i = 0; i < number_of_old_spline_points-1; i++) {
          #ifdef __CUDACC__

          // create and execute with streams
          cudaStreamCreate(&streams[i]);
          int num_blocks = std::ceil((unit_length[i] + NUM_THREADS -1)/NUM_THREADS);

          // sometimes a spline interval will have zero points
          if (num_blocks <= 0) continue;

          dim3 gridDim(num_blocks, 1);

          // launch one worker kernel per stream
          make_waveform<<<gridDim, NUM_THREADS, 0, streams[i]>>>(d_waveform,
                        interp_array,
                        d_m, d_n, num_teuk_modes, d_Ylms,
                        delta_t, h_t[i], i, start_inds[i], start_inds[i+1], init_len);
         #else

         // CPU waveform generation
         make_waveform(d_waveform,
                       interp_array,
                       d_m, d_n, num_teuk_modes, d_Ylms,
                       delta_t, h_t[i], i, start_inds[i], start_inds[i+1], init_len);
         #endif

      }

      //synchronize after all streams finish
      #ifdef __CUDACC__
      cudaDeviceSynchronize();
      gpuErrchk(cudaGetLastError());

      #ifdef __USE_OMP__
      #pragma omp parallel for
      #endif
      for (int i = 0; i < number_of_old_spline_points-1; i++) {
            //destroy the streams
            cudaStreamDestroy(streams[i]);
        }
      #endif
}

// make a frequency domain waveform in parallel
// this uses an efficient summation by loading mode information into shared memory
// shared memory is leveraged heavily

//  Copyright (c) 2006 Xiaogang Zhang
//  Use, modification and distribution are subject to the
//  Boost Software License, Version 1.0. (See accompanying file
//  LICENSE_1_0.txt or copy at http://www.boost.org/LICENSE_1_0.txt)

// Modified Bessel functions of the first and second kind of fractional order

const double epsilon = 2.2204460492503131e-016;
const int max_series_iterations = 1;
const double log_max_value = 709.0;
const double max_value = 1.79769e+308;
const int max_factorial = 170;
const double euler = 0.577215664901532860606;

/*
template<class _Tp>
CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
sinh(const gcmplx::complex<_Tp>& __x)
{
    if (std::isinf(__x.real()) && !isfinite(__x.imag()))
        return gcmplx::complex<_Tp>(__x.real(), _Tp(NAN));
    if (__x.real() == 0 && !isfinite(__x.imag()))
        return gcmplx::complex<_Tp>(__x.real(), _Tp(NAN));
    if (__x.imag() == 0 && !isfinite(__x.real()))
        return __x;
    return gcmplx::complex<_Tp>(sinh(__x.real()) * cos(__x.imag()), cosh(__x.real()) * sin(__x.imag()));
}
// cosh
template<class _Tp>
CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
cosh(const gcmplx::complex<_Tp>& __x)
{
    if (std::isinf(__x.real()) && !isfinite(__x.imag()))
        return gcmplx::complex<_Tp>(fabs(__x.real()), _Tp(NAN));
    if (__x.real() == 0 && !isfinite(__x.imag()))
        return gcmplx::complex<_Tp>(_Tp(NAN), __x.real());
    if (__x.real() == 0 && __x.imag() == 0)
        return gcmplx::complex<_Tp>(_Tp(1), __x.imag());
    if (__x.imag() == 0 && !isfinite(__x.real()))
        return gcmplx::complex<_Tp>(fabs(__x.real()), __x.imag());
    return gcmplx::complex<_Tp>(cosh(__x.real()) * cos(__x.imag()), sinh(__x.real()) * sin(__x.imag()));
}
template<class _Tp>
CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
sin(const gcmplx::complex<_Tp>& __x)
{
    gcmplx::complex<_Tp> __z = sinh(gcmplx::complex<_Tp>(-__x.imag(), __x.real()));
    return gcmplx::complex<_Tp>(__z.imag(), -__z.real());
}
// cos
template<class _Tp>
inline CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
cos(const gcmplx::complex<_Tp>& __x)
{
    return cosh(gcmplx::complex<_Tp>(-__x.imag(), __x.real()));
}
// log
template<class _Tp>
inline CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
log(const gcmplx::complex<_Tp>& __x)
{
    return gcmplx::complex<_Tp>(log(abs(__x)), arg(__x));
}
template<class _Tp>
CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
polar_complex(const _Tp& __rho, const _Tp& __theta = _Tp(0))
{
    if (isnan(__rho) || signbit(__rho))
        return gcmplx::complex<_Tp>(_Tp(NAN), _Tp(NAN));
    if (isnan(__theta))
    {
        if (std::isinf(__rho))
            return gcmplx::complex<_Tp>(__rho, __theta);
        return gcmplx::complex<_Tp>(__theta, __theta);
    }
    if (std::isinf(__theta))
    {
        if (std::isinf(__rho))
            return gcmplx::complex<_Tp>(__rho, _Tp(NAN));
        return gcmplx::complex<_Tp>(_Tp(NAN), _Tp(NAN));
    }
    _Tp __x = __rho * cos(__theta);
    if (isnan(__x))
        __x = 0;
    _Tp __y = __rho * sin(__theta);
    if (isnan(__y))
        __y = 0;
    return gcmplx::complex<_Tp>(__x, __y);
}
template<class _Tp>
CUDA_CALLABLE_MEMBER
gcmplx::complex<_Tp>
sqrt(const gcmplx::complex<_Tp>& __x)
{
    if (std::isinf(__x.imag()))
        return gcmplx::complex<_Tp>(_Tp(INFINITY), __x.imag());
    if (std::isinf(__x.real()))
    {
        if (__x.real() > _Tp(0))
            return gcmplx::complex<_Tp>(__x.real(), isnan(__x.imag()) ? __x.imag() : copysign(_Tp(0), __x.imag()));
        return gcmplx::complex<_Tp>(isnan(__x.imag()) ? __x.imag() : _Tp(0), copysign(__x.real(), __x.imag()));
    }
    return polar_complex(sqrt(abs(__x)), arg(__x) / _Tp(2));
}
*/
CUDA_CALLABLE_MEMBER
int iround(double x)
{
    double remain = fmod(x, 1.0);
    double temp;
    if (remain >= 0.5)
    {
        temp = ceil(x);
    }
    else
    {
        temp = floor(x);
    }
   return int(temp);
}

CUDA_CALLABLE_MEMBER
double tgamma1pm1(double dz)
{
  return tgamma(dz + 1.) - 1.;
}


// Calculate K(v, x) and K(v+1, x) by method analogous to
// Temme, Journal of Computational Physics, vol 21, 343 (1976)
CUDA_CALLABLE_MEMBER
int temme_ik(double v, cmplx x, cmplx* K, cmplx* K1)
{
    cmplx f, h, p, q, coef, sum, sum1;
    cmplx a, b, c, d, sigma, gamma1, gamma2;
    unsigned long kk;
    double k, tolerance;

    // |x| <= 2, Temme series converge rapidly
    // |x| > 2, the larger the |x|, the slower the convergence
    //BOOST_ASSERT(abs(x) <= 2);
    //BOOST_ASSERT(abs(v) <= 0.5f);

    double gp = tgamma1pm1(v);
    double gm = tgamma1pm1(-v);

    a = log(x / 2.);
    b = exp(v * a);
    sigma = -a * v;

    c = abs(v) < epsilon ?
       1.0 : sin(M_PI * v) / (v * M_PI);
    d = abs(sigma) < epsilon ?
        1.0 : sinh(sigma) / sigma;
    gamma1 = abs(cmplx(v, 0.0)) < epsilon ?
        -euler : (0.5 / v) * (gp - gm) * c;
    gamma2 = (2. + gp + gm) * c / 2.;

    // initial values
    p = (gp + 1.) / (2. * b);
    q = (1. + gm) * b / 2.;
    f = (cosh(sigma) * gamma1 + d * (-a) * gamma2) / c;
    h = p;
    coef = 1.;
    sum = coef * f;
    sum1 = coef * h;

    // series summation
    tolerance = epsilon;
    for (kk = 1; kk < max_series_iterations; kk++)
    {
        k = double(kk);

        f = (k * f + p + q) / (k*k - v*v);
        p /= k - v;
        q /= k + v;
        h = p - k * f;
        coef *= x * x / (4. * k);
        sum += coef * f;
        sum1 += coef * h;
        if (abs(coef * f) < abs(sum) * tolerance)
        {
           break;
        }
    }

    *K = sum;
    *K1 = 2. * sum1 / x;

    return 0;
}



// Calculate K(v, x) and K(v+1, x) by evaluating continued fraction
// z1 / z0 = U(v+1.5, 2v+1, 2x) / U(v+0.5, 2v+1, 2x), see
// Thompson and Barnett, Computer Physics Communications, vol 47, 245 (1987)
CUDA_CALLABLE_MEMBER
int CF2_ik(double v, cmplx x, cmplx* Kv, cmplx* Kv1)
{
    double tolerance;
    cmplx S, C, Q, D, f, a, b, q, delta, current, prev;
    unsigned long k;

    // |x| >= |v|, CF2_ik converges rapidly
    // |x| -> 0, CF2_ik fails to converge

    // TODO: deal with this line
    //assert(abs(x) > 1);

    // Steed's algorithm, see Thompson and Barnett,
    // Journal of Computational Physics, vol 64, 490 (1986)
    tolerance = epsilon;
    a = v * v - 0.25f;
    b = 2. * (x + 1.);                              // b1
    D = 1. / b;                                    // D1 = 1 / b1
    f = delta = D;                                // f1 = delta1 = D1, coincidence
    prev = 0;                                     // q0
    current = 1;                                  // q1
    Q = C = -a;                                   // Q1 = C1 because q1 = 1
    S = 1. + Q * delta;                            // S1

    for (k = 2; k < max_series_iterations; k++)     // starting from 2
    {
        // continued fraction f = z1 / z0
        a -= 2 * (k - 1);
        b += 2;
        D = 1. / (b + a * D);
        delta *= b * D - 1.;
        f += delta;

        // series summation S = 1 + \sum_{n=1}^{\infty} C_n * z_n / z_0
        q = (prev - (b - 2.) * current) / a;
        prev = current;
        current = q;                        // forward recurrence for q
        C *= -a / double(k);
        Q += C * q;
        S += Q * delta;
        //
        // Under some circumstances q can grow very small and C very
        // large, leading to under/overflow.  This is particularly an
        // issue for types which have many digits precision but a narrow
        // exponent range.  A typical example being a "double double" type.
        // To avoid this situation we can normalise q (and related prev/current)
        // and C.  All other variables remain unchanged in value.  A typical
        // test case occurs when x is close to 2, for example cyl_bessel_k(9.125, 2.125).
        //
        if(abs(q) < epsilon)
        {
           C *= q;
           prev /= q;
           current /= q;
           q = 1;
        }

        // S converges slower than f
        if (abs(Q * delta) < abs(S) * tolerance)
        {
           break;
        }
    }

    if(abs(x) >= log_max_value)
       *Kv = gcmplx::exp(0.5 * log(M_PI / (2. * x)) - x - log(S));
    else
      *Kv = sqrt(M_PI / (2. * x)) * gcmplx::exp(-x) / S;
    *Kv1 = *Kv * (0.5 + v + x + (v * v - 0.25) * f) / x;
    return 0;
}


// Compute I(v, x) and K(v, x) simultaneously by Temme's method, see
// Temme, Journal of Computational Physics, vol 19, 324 (1975)
CUDA_CALLABLE_MEMBER
int bessel_ik(double v, cmplx x, cmplx* K)
{
    // Kv1 = K_(v+1), fv = I_(v+1) / I_v
    // Ku1 = K_(u+1), fu = I_(u+1) / I_u
    double u;
    cmplx Iv, Kv, Kv1, Ku, Ku1, fv;
    cmplx W, current, prev, next;
    bool reflect = false;
    unsigned n, k;

    if (v < 0)
    {
        reflect = true;
        v = -v;                             // v is non-negative from here
    }
    n = iround(v);
    u = v - n;                              // -1/2 <= u < 1/2

    // x is positive until reflection
    //W = 1 / x;                                 // Wronskian
    if (abs(x) <= 2)                                // x in (0, 2]
    {
       temme_ik(u, x, &Ku, &Ku1);             // Temme series
    }
    else                                       // x in (2, \infty)
    {
        CF2_ik(u, x, &Ku, &Ku1);           // continued fraction CF2_ik
    }


    prev = Ku;
    current = Ku1;

    cmplx scale = 1.0;
    /*
    for (k = 1; k <= n; k++)                   // forward recurrence for K
    {
        cmplx fact = cmplx(2. * (u + k), 0.0) / x;
        if((max_value - std::abs(prev)) / std::abs(fact) < std::abs(current))
        {
           prev /= current;
           scale /= current;
           current = 1;
        }
        next = fact * current + prev;
        prev = current;
        current = next;
    }
    */
    Kv = prev;
    Kv1 = current;

    *K = Kv / scale;

    return 0;
}

CUDA_CALLABLE_MEMBER
cmplx kve(double v, cmplx x)
{
    cmplx K;
    bessel_ik(v, x, &K);
    return K * gcmplx::exp(x);
}

#define MAX_SEGMENTS_BLOCK 400

CUDA_CALLABLE_MEMBER
cmplx SPAFunc(const double x)
{

    //$x = (2\pi/3)\dot f^3/\ddot f^2$ and spafunc is $i \sqrt{x} e^{-i x} K_{1/3}(-i x)$.
  cmplx II(0.0, 1.0);
  cmplx ans;
  const double Gamp13 = 2.67893853470774763;  // Gamma(1/3)
  const double Gamm13 = -4.06235381827920125; // Gamma(-1/3);
  if (abs(x) <= 7.) {
    const cmplx xx = ((cmplx)x);
    const cmplx pref1 = gcmplx::exp(-2.*M_PI*II/3.)*pow(xx, 5./6.)*Gamm13/pow(2., 1./3.);
    const cmplx pref2 = gcmplx::exp(-M_PI*II/3.)*pow(xx, 1./6.)*Gamp13/pow(2., 2./3.);
    const double x2 = x*x;

    const double c1_0 = 0.5, c1_2 = -0.09375, c1_4 = 0.0050223214285714285714;
    const double c1_6 = -0.00012555803571428571429, c1_8 = 1.8109332074175824176e-6;
    const double c1_10 = -1.6977498819539835165e-8, c1_12 = 1.1169407118118312608e-10;
    const double c1_14 = -5.4396463237589184781e-13, c1_16 = 2.0398673714095944293e-15;
    const double c1_18 = -6.0710338434809358015e-18, c1_20 = 1.4687985105195812423e-20;
    const double c1_22 = -2.9454515585285720100e-23, c1_24 = 4.9754249299469121790e-26;
    const double c1_26 = -7.1760936489618925658e-29;

    const double ser1 = c1_0 + x2*(c1_2 + x2*(c1_4 + x2*(c1_6 + x2*(c1_8 + x2*(c1_10 + x2*(c1_12 + x2*(c1_14 + x2*(c1_16 + x2*(c1_18 + x2*(c1_20 + x2*(c1_22 + x2*(c1_24 + x2*c1_26))))))))))));

    const double c2_0 = 1., c2_2 = -0.375, c2_4 = 0.028125, c2_6 = -0.00087890625;
    const double c2_8 = 0.000014981356534090909091, c2_10 = -1.6051453429383116883e-7;
    const double c2_12 = 1.1802539286311115355e-9, c2_14 = -6.3227889033809546546e-12;
    const double c2_16 = 2.5772237377911499951e-14, c2_18 = -8.2603324929203525483e-17;
    const double c2_20 = 2.1362928861000911763e-19, c2_22 = -4.5517604107246260858e-22;
    const double c2_24 = 8.1281435905796894390e-25, c2_26 = -1.2340298973552160079e-27;

    const double ser2 = c2_0 + x2*(c2_2 + x2*(c2_4 + x2*(c2_6 + x2*(c2_8 + x2*(c2_10 + x2*(c2_12 + x2*(c2_14 + x2*(c2_16 + x2*(c2_18 + x2*(c2_20 + x2*(c2_22 + x2*(c2_24 + x2*c2_26))))))))))));

    ans = gcmplx::exp(-II*x)*(pref1*ser1 + pref2*ser2);
  } else {
    const cmplx y = 1./x;
    const cmplx pref = gcmplx::exp(-0.75*II*M_PI)*sqrt(0.5*M_PI);

    const cmplx c_0 = II, c_1 = 0.069444444444444444444, c_2 = -0.037133487654320987654*II;
    const cmplx c_3 = -0.037993059127800640146, c_4 = 0.057649190412669721333*II;
    const cmplx c_5 = 0.11609906402551541102, c_6 = -0.29159139923075051147*II;
    const cmplx c_7 = -0.87766696951001691647, c_8 = 3.0794530301731669934*II;

    cmplx ser = c_0+y*(c_1+y*(c_2+y*(c_3+y*(c_4+y*(c_5+y*(c_6+y*(c_7+y*c_8)))))));

    ans = pref*ser;
  }
  return(ans);
}


// build mode value with specific phase and amplitude values; mode indexes; and spherical harmonics
CUDA_CALLABLE_MEMBER
cmplx get_mode_value_fd(double t, double f, double fdot, double fddot, cmplx amp_term1, double phase_term, cmplx Ylm){
    cmplx I(0.0, 1.0);

    // Waveform Amplitudes
    //cmplx arg = -I* 2.* PI * pow(fdot, 3) / (3.* pow(fddot, 2));
    //cmplx K_1over3 =  kve(1./3.,arg); // #special.kv(1./3.,arg)*np.exp(arg);

    // to correct the special function nan
    //if np.sum(np.isnan(special.kv(1/3,arg)))>0:
    //    print('number of nans',np.sum(np.isnan(special.kv(1/3,arg))))
    //  #print(arg[np.isnan(special.kv(1./3.,arg))])

    //  X = 2*PI*fdot**3 / (3*fddot**2)
    //  #K_1over3[np.isnan(special.kv(1./3.,arg))] = (np.sqrt(PI/2) /(I*np.sqrt(np.abs(X))) * np.exp(-I*PI/4) )[np.isnan(special.kv(1./3.,arg))]
    //  #print('isnan',np.sum(np.isnan(arg)),np.sum(np.isnan(fdot/np.abs(fddot))))

    //cmplx amp_term2 = I* fdot/abs(fddot) * K_1over3 * 2./sqrt(3.);

    // $x = (2\pi/3)\dot f^3/\ddot f^2$ and spafunc is $i \sqrt{x} e^{-i x} K_{1/3}(-i x)$.
    double arg = 2.* PI * pow(fdot, 3) / (3.* pow(fddot, 2));
    cmplx amp_term2 = -1.0 * fdot/abs(fddot) * 2./sqrt(3.) * SPAFunc(arg) / gcmplx::sqrt(cmplx(arg, 0.0));
    //cmplx amp_term2 = 0.0;
    cmplx out = amp_term1 * Ylm * amp_term2
                * gcmplx::exp(
                    I* (2. * PI * f * t - phase_term)
                );

    cmplx temp = gcmplx::exp(
        I* (2. * PI * f * t - phase_term)
    );

    //if (abs(f) == 0.0)
    //{
    //    printf("IN: %d %.18e %.18e %.18e %.18e %.18e %.18e\n", f > 0.0, amp_term1.real(), amp_term1.imag(), amp_term2.real(), amp_term2.imag(), temp.real(), temp.imag());
    //}

    return out;
}

CUDA_CALLABLE_MEMBER
double get_special_f(double f, double sign_slope, double Fstar)
{
    if (sign_slope > 0)
    {
        double special_f = Fstar + Fstar / abs(Fstar) * abs(f - Fstar);
    }
    else
    {
        double special_f = -(Fstar + Fstar / abs(Fstar) * abs(f - Fstar));
    }
}

CUDA_KERNEL
void make_waveform_fd(cmplx *waveform,
             double *interp_array,
             double *special_f_interp_array,
             double* special_f_seg_in,
              int *m_arr_in, int *n_arr_in, int num_teuk_modes, cmplx *Ylms_in,
              double* t_arr, int* start_ind_all, int* end_ind_all, int init_length,
              double start_freq, int* turnover_ind_all,
              double* turnover_freqs, double df, double* f_data, int zero_index)

{

    #ifdef __CUDACC__
    int mode_start = blockIdx.y;
    int mode_increment = gridDim.y;
    #else
    int mode_start = 0;
    int mode_increment = 1;
    #pragma omp parallel for
    #endif
    for (int mode_i = mode_start; mode_i < num_teuk_modes; mode_i += mode_increment)
    {

        int turnover_ind = turnover_ind_all[mode_i];
        double turnover_frequency = turnover_freqs[mode_i];

        #ifdef __CUDACC__
        int segment_start = blockIdx.z;
        int segment_increment = gridDim.z;
        #else
        int segment_start = 0;
        int segment_increment = 1;
        #pragma omp parallel for
        #endif
        // init_length -1 because thats the number of segments
        for (int segment_i = segment_start; segment_i < init_length - 1; segment_i += segment_increment)
        {

            // number of additional splines beyond real and imaginary of amplitudes
            int num_pars = 4;

            cmplx complexI(0.0, 1.0);

             // declare all the shared memory
             // MAX_SEGMENTS_BLOCK` is fixed based on shared memory
             CUDA_SHARED double mode_re_y;
             CUDA_SHARED double mode_re_c1;
             CUDA_SHARED double mode_re_c2;
             CUDA_SHARED double mode_re_c3;

             CUDA_SHARED double mode_im_y;
             CUDA_SHARED double mode_im_c1;
             CUDA_SHARED double mode_im_c2;
             CUDA_SHARED double mode_im_c3;

             CUDA_SHARED double pp_y;
             CUDA_SHARED double pp_c1;
             CUDA_SHARED double pp_c2;
             CUDA_SHARED double pp_c3;

             CUDA_SHARED double pr_y;
             CUDA_SHARED double pr_c1;
             CUDA_SHARED double pr_c2;
             CUDA_SHARED double pr_c3;

             CUDA_SHARED double fp_end_y;
             CUDA_SHARED double fp_y;
             CUDA_SHARED double fp_c1;
             CUDA_SHARED double fp_c2;
             CUDA_SHARED double fp_c3;

             CUDA_SHARED double fr_end_y;
             CUDA_SHARED double fr_y;
             CUDA_SHARED double fr_c1;
             CUDA_SHARED double fr_c2;
             CUDA_SHARED double fr_c3;

             //CUDA_SHARED double tf_y;
             CUDA_SHARED double tf_c1;
             CUDA_SHARED double tf_c2;
             CUDA_SHARED double tf_c3;

             CUDA_SHARED double t_seg;
             CUDA_SHARED double special_f_seg;

             CUDA_SHARED int m;
             CUDA_SHARED int n;

             CUDA_SHARED cmplx Ylm_plus_m;
             CUDA_SHARED cmplx Ylm_minus_m;

             CUDA_SHARED double initial_frequency;
             CUDA_SHARED double end_frequency;
             CUDA_SHARED double turnover_time;
             CUDA_SHARED double special_f[2];

             CUDA_SHARED double sign_slope;


             // number of splines
             int num_base = init_length * (2 * num_teuk_modes + num_pars);
             int num_base_tf = init_length * num_teuk_modes;



             CUDA_SYNC_THREADS;

             #ifdef __CUDACC__
             if (threadIdx.x == 0)
             #else
             if (true)
             #endif
             {
                // fill phase values. These will be same for all modes
                int ind_Phi_phi = segment_i * (num_teuk_modes*2 + num_pars) + (num_teuk_modes*2 + 2);
                int ind_Phi_r = segment_i * (num_teuk_modes*2 + num_pars) + (num_teuk_modes*2 + 3);

                int ind_f_phi = segment_i * (num_teuk_modes*2 + num_pars) + (num_teuk_modes*2 + 0);
                int ind_f_r = segment_i * (num_teuk_modes*2 + num_pars) + (num_teuk_modes*2 + 1);

                pp_y = interp_array[0 * num_base + ind_Phi_phi]; pp_c1 = interp_array[1 * num_base + ind_Phi_phi];
                pp_c2 = interp_array[2 * num_base + ind_Phi_phi];  pp_c3 = interp_array[3 * num_base + ind_Phi_phi];

                pr_y = interp_array[0 * num_base + ind_Phi_r]; pr_c1 = interp_array[1 * num_base + ind_Phi_r];
                pr_c2 = interp_array[2 * num_base + ind_Phi_r];  pr_c3 = interp_array[3 * num_base + ind_Phi_r];

                fp_y = interp_array[0 * num_base + ind_f_phi]; fp_c1 = interp_array[1 * num_base + ind_f_phi];
                fp_c2 = interp_array[2 * num_base + ind_f_phi];  fp_c3 = interp_array[3 * num_base + ind_f_phi];

                fr_y = interp_array[0 * num_base + ind_f_r]; fr_c1 = interp_array[1 * num_base + ind_f_r];
                fr_c2 = interp_array[2 * num_base + ind_f_r];  fr_c3 = interp_array[3 * num_base + ind_f_r];

                int ind_f_phi_end = (segment_i + 1) * (num_teuk_modes*2 + num_pars) + (num_teuk_modes*2 + 0);
                int ind_f_r_end = (segment_i + 1) * (num_teuk_modes*2 + num_pars) + (num_teuk_modes*2 + 1);

                fp_end_y = interp_array[0 * num_base + ind_f_phi_end];
                fr_end_y = interp_array[0 * num_base + ind_f_r_end];

                int ind_mode_re = segment_i * (num_teuk_modes*2 + num_pars) + mode_i;
                int ind_mode_im = segment_i * (num_teuk_modes*2 + num_pars) + num_teuk_modes + mode_i;

                mode_re_y = interp_array[0 * num_base + ind_mode_re]; mode_re_c1 = interp_array[1 * num_base + ind_mode_re];
                mode_re_c2 = interp_array[2 * num_base + ind_mode_re];  mode_re_c3 = interp_array[3 * num_base + ind_mode_re];

                mode_im_y = interp_array[0 * num_base + ind_mode_im]; mode_im_c1 = interp_array[1 * num_base + ind_mode_im];
                mode_im_c2 = interp_array[2 * num_base + ind_mode_im];  mode_im_c3 = interp_array[3 * num_base + ind_mode_im];

                t_seg = t_arr[segment_i];

                int ind_tf = segment_i * num_teuk_modes + mode_i;

                tf_c1 = special_f_interp_array[1 * num_base_tf + ind_tf];
                tf_c2 = special_f_interp_array[2 * num_base_tf + ind_tf];
                tf_c3 = special_f_interp_array[3 * num_base_tf + ind_tf];

                //if ((m == 1) && (n == -4) && (segment_i == 100))
                //{
                //    printf("%d %d %e %e %e %e\n", num_base_tf, ind_tf, t_seg, tf_c1, tf_c2, tf_c3);
                //}

                special_f_seg = special_f_seg_in[ind_tf];

                 m = m_arr_in[mode_i];
                 n = n_arr_in[mode_i];

                 Ylm_plus_m = Ylms_in[mode_i];
                 Ylm_minus_m = Ylms_in[num_teuk_modes + mode_i];
             }
             CUDA_SYNC_THREADS;

            int ind_inds = mode_i * (init_length - 1) + segment_i;
            int start_ind = start_ind_all[ind_inds];
            int end_ind = end_ind_all[ind_inds];
            #ifdef __CUDACC__
            int start = start_ind + blockIdx.x * blockDim.x + threadIdx.x;
            int diff = blockDim.x * gridDim.x;
            #else

            int start = start_ind;
            int diff = 1;
            #endif
            #ifdef __CUDACC__
            #else
            #ifdef __USE_OMP__
            #pragma omp parallel for
            #endif // __USE_OMP__
            #endif // __CUDACC__

                // start and end is the start and end of points in this interpolation window
                // start is index of min f and end is index of max f

            for (int i = start;
                 i <= end_ind; // goes from ceil to floor so need to <=
                 i += diff)
            {
                cmplx trans(0.0, 0.0);
                double f = f_data[i]; //  start_freq + df * i;
                double Fstar = turnover_frequency;

                int num_points;
                double slope0;
                special_f[0] = 0.0;
                special_f[1] = 0.0;

                double f_seg_begin = m * fp_y + n * fr_y;
                double f_seg_end = m * fp_end_y + n * fr_end_y;

                if (segment_i > turnover_ind)
                {
                    num_points = 1;
                    // slope at beginning of this segment
                    slope0 = m * fp_c1 + n * fr_c1;

                    if (slope0 < 0.0)
                    {
                        special_f[0] = abs(Fstar + Fstar / abs(Fstar) * abs(f - Fstar));
                        //if ((f == 0.0))
                        //{
                        //    printf("AHAH1: %d %d %d %.18e %.18e %.18e\n", turnover_ind, mode_i, segment_i, special_f[0], f, Fstar);
                        //}
                    }
                    else
                    {
                        // TODO: check this special_f
                        special_f[0] = abs(Fstar + Fstar / abs(Fstar) * abs(f - Fstar));
                        //if ((f == 0.0))
                        //{
                        //    printf("AHAH2: %d %d %d %.18e %.18e %.18e\n", turnover_ind, mode_i, segment_i, special_f[0], f, Fstar);
                        //}
                    }


                }
                else if (segment_i < turnover_ind)
                {
                    num_points = 1;
                    special_f[0] = abs(f);
                }
                else
                {
                    // slope at beginning of this segment
                    slope0 = m * fp_c1 + n * fr_c1;

                    if ((abs(f) > abs(f_seg_begin)) && (abs(f) > abs(f_seg_end)))
                    {
                        //if (f == 0.0)
                        //{
                        //    printf("YAYAY: %d %d %d %.18e %.18e %.18e\n", turnover_ind, mode_i, segment_i, special_f[0], f, Fstar);
                        //}

                        num_points = 2;
                        special_f[0] = abs(f);

                        // this is beginning of segment, so past turnover will have opposite slope
                        if (slope0 < 0.0)
                        {
                            special_f[1] = abs(Fstar + Fstar / abs(Fstar) * abs(f - Fstar));
                        }
                        else
                        {
                            // TODO: check this special_f
                            special_f[1] = abs(Fstar - Fstar / abs(Fstar) * abs(f - Fstar));
                        }
                    }
                    else if (abs(f) > abs(f_seg_begin))
                    {
                        num_points = 1;
                        special_f[0] = abs(f);
                    }
                    else // (abs(f) > abs(f_seg_end))
                    {
                        num_points = 1;
                        if (slope0 < 0.0)
                        {
                            special_f[0] = abs(Fstar - Fstar / abs(Fstar) * abs(f - Fstar));
                            //if (f == 0.0)
                            //{
                            //    printf("YAYAY3: %d %d %d %.18e %.18e %.18e\n", turnover_ind, mode_i, segment_i, special_f[0], f, Fstar);
                            //}
                        }
                        else
                        {
                            // TODO: check this special_f
                            special_f[0] = abs(Fstar - Fstar / abs(Fstar) * abs(f - Fstar));
                            //if (f == 0.0)
                            //{
                            //    printf("YAYAY4: %d %d %d %.18e %.18e %.18e\n", turnover_ind, mode_i, segment_i, special_f[0], f, Fstar);
                            //}

                        }
                    }
                }

                //if (i == 1552316)
                //{
                //    printf("%d %d %d %.18e %.18e %.18e %.18e %.18e %.18e %.18e\n", segment_i, turnover_ind, num_points, slope0, f, f_seg_begin, f_seg_end, special_f[0], special_f[1], Fstar);
                //}
                //printf("%d %d %d %d %d %d %e %e %e %e %e %d %d\n", i, mode_i, segment_i, start_ind, end_ind, num_points, f, Fstar, special_f[0], special_f[1], segment_i > turnover_ind, segment_i < turnover_ind);
                //printf("%d %d %d %d %d %d %d %d %d %d\n", i, mode_i, segment_i, start_ind, end_ind, init_length, ind_inds, start_ind_all[ind_inds - 1], start_ind_all[ind_inds], start_ind_all[ind_inds + 1]);

                // determine interpolation information

                int minus_m_freq_index;
                int diff = abs(zero_index - i);
                if (i < zero_index)
                {
                    minus_m_freq_index = zero_index + diff;
                }
                else
                {
                    minus_m_freq_index = zero_index - diff;
                }//= int((-f - start_freq) / df) + 1;
                cmplx trans_plus_m(0.0, 0.0);
                cmplx trans_minus_m(0.0, 0.0);

                for (int jj = 0; jj < num_points; jj += 1)
                {

                    double x_f = special_f[jj] - special_f_seg;
                    double x_f2 = x_f*x_f;
                    double x_f3 = x_f2*x_f;

                    double t = t_seg + tf_c1 * x_f + tf_c2 * x_f2 + tf_c3 * x_f3;

                    //if ((f == 0.0))
                    //{
                    //    printf("he: %d %d %d %.18e %.18e %.18e %.18e %.18e %.18e %.18e\n", turnover_ind, mode_i, segment_i, special_f[jj], special_f_seg, f, Fstar, x_f, t_seg, t);
                    //}

                    double x = t - t_seg;
                    double x2 = x * x;
                    double x3 = x * x2;

                    // get phases at this timestep
                    double Phi_phi_i = pp_y + pp_c1*x + pp_c2*x2  + pp_c3*x3;
                    double Phi_r_i = pr_y + pr_c1*x + pr_c2*x2  + pr_c3*x3;

                    // calculate mode at this timestep
                    double mode_val_re =  mode_re_y + mode_re_c1*x + mode_re_c2*x2  + mode_re_c3*x3;
                    double mode_val_im = mode_im_y + mode_im_c1*x + mode_im_c2*x2  + mode_im_c3*x3;
                    cmplx mode_val = mode_val_re + complexI*mode_val_im;

                    // calculate f, fdot, fddot, phase
                    double f_phi = fp_y + fp_c1*x + fp_c2*x2  + fp_c3*x3;
                    double f_r = fp_y + fp_c1*x + fp_c2*x2  + fp_c3*x3;

                    double f_phi_dot = fp_c1 + 2. * fp_c2 * x + 3. * fp_c3 * x2;
                    double f_r_dot = fr_c1 + 2. * fr_c2 * x + 3. * fr_c3 * x2;
                    double fdot = m * f_phi_dot + n * f_r_dot;

                    double f_phi_ddot = 2. * fp_c2 + 6. * fp_c3 * x;
                    double f_r_ddot = 2. * fr_c2 + 6. * fr_c3 * x;
                    double fddot = m * f_phi_ddot + n * f_r_ddot;

                    double phase_term = m * Phi_phi_i + n * Phi_r_i;

                    trans_plus_m += get_mode_value_fd(t, f, fdot, fddot, mode_val, phase_term, Ylm_plus_m);

                    //printf("check: %d %d %d x_f: %.18e %.18e %.18e %.18e %.18e %.18e %.18e %.18e %.18e\n", i, jj, segment_i, t, x_f, special_f[jj], special_f_seg, start_freq, df, f, fdot, fddot);  //;
                    //if (i == 1541651)
                    //printf("%.18e %.18e %.18e %.18e %.18e\n", mode_val.real(), mode_val.imag(), phase_term, trans_plus_m.real(), trans_plus_m.imag());
                    // minus m if m > 0
                    // mode values for +/- m are taking care of when applying
                    //specific mode selection by setting ylms to zero for the opposites

                    if (m != 0)
                    {
                        trans_minus_m += get_mode_value_fd(t, -f, -fdot, -fddot, gcmplx::conj(mode_val), -phase_term, Ylm_minus_m);

                    } else trans_minus_m += 0.0 + 0.0*complexI;

                    //if (i == 1541654) printf("%d %d %d %d %.18e %.18e %.18e %.18e %.18e %.18e %.18e %.18e %.18e %.18e %.18e\n", jj, minus_m_freq_index, m, n, t, -f, -fdot, -fddot, gcmplx::conj(mode_val).real(), gcmplx::conj(mode_val).imag(), -phase_term, Ylm_minus_m.real(), Ylm_minus_m.imag(), trans_minus_m.real(), trans_minus_m.imag());

                }
                // fill waveform
                #ifdef __CUDACC__
                atomicAddcmplx(&waveform[i], trans_plus_m);
                #else
                waveform[i] += trans_plus_m;
                #endif

                if (m != 0.0)
                {
                    #ifdef __CUDACC__
                    atomicAddcmplx(&waveform[minus_m_freq_index], trans_minus_m);
                    #else
                    waveform[minus_m_freq_index] += trans_minus_m;
                    #endif
                }
            }
        }
    }
}


// function for building interpolated EMRI waveform from python
void get_waveform_fd(cmplx *waveform,
             double *interp_array,
             double *special_f_interp_array,
             double* special_f_seg_in,
              int *m_arr_in, int *n_arr_in, int num_teuk_modes, cmplx *Ylms_in,
              double* t_arr, int* start_ind_all, int* end_ind_all, int init_length,
              double start_freq, int* turnover_ind_all,
              double* turnover_freqs, int max_points, double df, double* f_data, int zero_index)
{

    #ifdef __CUDACC__

    // prepare streams for CUDA
    int NUM_THREADS = 256;

    int num_blocks = std::ceil((max_points + NUM_THREADS -1)/NUM_THREADS);

    //printf("%d %d %d\n", num_blocks, num_teuk_modes, init_length - 1);
    dim3 gridDim(1, num_teuk_modes, init_length - 1);

    make_waveform_fd<<<gridDim, NUM_THREADS>>>(waveform,
                 interp_array,
                 special_f_interp_array,
                 special_f_seg_in,
                  m_arr_in, n_arr_in, num_teuk_modes, Ylms_in,
                  t_arr, start_ind_all, end_ind_all, init_length,
                  start_freq, turnover_ind_all,
                  turnover_freqs, df, f_data, zero_index);
    cudaDeviceSynchronize();
    gpuErrchk(cudaGetLastError());

    #else

    make_waveform_fd(waveform,
                 interp_array,
                 special_f_interp_array,
                 special_f_seg_in,
                  m_arr_in, n_arr_in, num_teuk_modes, Ylms_in,
                  t_arr, start_ind_all, end_ind_all, init_length,
                  start_freq, turnover_ind_all,
                  turnover_freqs, df, f_data, zero_index);

    #endif
}
