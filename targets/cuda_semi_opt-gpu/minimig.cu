#include "cuda_runtime.h"
#include "device_launch_parameters.h"

#include <stdio.h>
#include <float.h>
#include <math.h>
#include <time.h>

#include "../../constants.h"

#define N_RADIUS 4
#define N_THREADS_SEMI 8

__global__ void target_inner_3d_kernel(
    llint nx, llint ny, llint nz,
    llint x3, llint x4, llint y3, llint y4, llint z3, llint z4,
    llint lx, llint ly, llint lz,
    float hdx_2, float hdy_2, float hdz_2,
    float coef0,
    float coefx_1, float coefx_2, float coefx_3, float coefx_4,
    float coefy_1, float coefy_2, float coefy_3, float coefy_4,
    float coefz_1, float coefz_2, float coefz_3, float coefz_4,
    const float *__restrict__ u, float *__restrict__ v, const float *__restrict__ vp,
    const float *__restrict__ phi, const float *__restrict__ eta
) {
    __shared__ float partial_result[N_THREADS_SEMI][N_THREADS_SEMI][N_THREADS_SEMI];
    if (threadIdx.z < N_THREADS_SEMI) {
        partial_result[threadIdx.z][threadIdx.y][threadIdx.x] = 0.0;
    }
    __syncthreads();

    const llint i0 = x3 + blockIdx.x * N_THREADS_SEMI;
    const llint j0 = y3 + blockIdx.y * N_THREADS_SEMI;
    const llint k0 = z3 + blockIdx.z * N_THREADS_SEMI;

    const llint ie = min(x4, i0+N_THREADS_SEMI);
    const llint je = min(y4, j0+N_THREADS_SEMI);
    const llint ke = min(z4, k0+N_THREADS_SEMI);

    // jk-plane moves along the i-axis
    const llint ji = j0 + threadIdx.y;
    const llint ki = k0 + threadIdx.x;
    if (ji < je && ki < ke) {
        llint i_length = ie-i0;
        int i = threadIdx.z;
        if (i < i_length + N_RADIUS) {
            float d0 = u[IDX3_l(i0+i-4,ji,ki)];
            float d1 = u[IDX3_l(i0+i-3,ji,ki)];
            float d2 = u[IDX3_l(i0+i-2,ji,ki)];
            float d3 = u[IDX3_l(i0+i-1,ji,ki)];
            float d4 = u[IDX3_l(i0+i,ji,ki)];
            if (i < i_length) {
                atomicAdd(&partial_result[i][threadIdx.y][threadIdx.x],
                    coefx_1*d3 + coefx_2*d2 + coefx_3*d1 + coefx_4*d0);
            }
            if (i >= N_RADIUS) {
                atomicAdd(&partial_result[i-N_RADIUS][threadIdx.y][threadIdx.x],
                    coefx_1*d1 + coefx_2*d2 + coefx_3*d3 + coefx_4*d4);
            }
        }
    }

    // ik-plane moves along the j-axis
    const llint ij = i0 + threadIdx.y;
    const llint kj = k0 + threadIdx.x;
    if (ij < ie && kj < ke) {
        llint j_length = je-j0;
        int j = threadIdx.z;
        if (j < j_length + N_RADIUS) {
            float d0 = u[IDX3_l(ij,j0+j-4,kj)];
            float d1 = u[IDX3_l(ij,j0+j-3,kj)];
            float d2 = u[IDX3_l(ij,j0+j-2,kj)];
            float d3 = u[IDX3_l(ij,j0+j-1,kj)];
            float d4 = u[IDX3_l(ij,j0+j,kj)];
            if (j < j_length) {
                atomicAdd(&partial_result[threadIdx.y][j][threadIdx.x],
                    coefy_1*d3 + coefy_2*d2 + coefy_3*d1 + coefy_4*d0);
            }
            if (j >= N_RADIUS) {
                atomicAdd(&partial_result[threadIdx.y][j-N_RADIUS][threadIdx.x],
                    coefy_1*d1 + coefy_2*d2 + coefy_3*d3 + coefy_4*d4);
            }
        }
    }

    // ij-plane moves along the k-axis
    const llint ik = i0 + threadIdx.y;
    const llint jk = j0 + threadIdx.x;
    if (ik < ie && jk < je) {
        llint k_length = ke-k0;
        int k = threadIdx.z;
        if (k < k_length + N_RADIUS) {
            float d0 = u[IDX3_l(ik,jk,k0+k-4)];
            float d1 = u[IDX3_l(ik,jk,k0+k-3)];
            float d2 = u[IDX3_l(ik,jk,k0+k-2)];
            float d3 = u[IDX3_l(ik,jk,k0+k-1)];
            float d4 = u[IDX3_l(ik,jk,k0+k)];

            if (k < k_length) {
                atomicAdd(&partial_result[threadIdx.y][threadIdx.x][k],
                    coefz_1*d3 + coefz_2*d2 + coefz_3*d1 + coefz_4*d0);
            }

            __syncthreads();

            if (k >= N_RADIUS) {
                float lap = coef0*d0
                          + coefz_1*d1
                          + coefz_2*d2
                          + coefz_3*d3
                          + coefz_4*d4
                          + partial_result[threadIdx.y][threadIdx.x][k-N_RADIUS];

                llint kk = k0 + k - N_RADIUS;
                v[IDX3_l(ik,jk,kk)] = __fmaf_rn(2.f, d0,
                    __fmaf_rn(vp[IDX3(ik,jk,kk)], lap, -v[IDX3_l(ik,jk,kk)])
                );
            }
        }
    }
}

__global__ void target_pml_3d_kernel(
    llint nx, llint ny, llint nz,
    llint x3, llint x4, llint y3, llint y4, llint z3, llint z4,
    llint lx, llint ly, llint lz,
    float hdx_2, float hdy_2, float hdz_2,
    float coef0,
    float coefx_1, float coefx_2, float coefx_3, float coefx_4,
    float coefy_1, float coefy_2, float coefy_3, float coefy_4,
    float coefz_1, float coefz_2, float coefz_3, float coefz_4,
    const float *__restrict__ u, float *__restrict__ v, const float *__restrict__ vp,
    float *__restrict__ phi, const float *__restrict__ eta
) {
    __shared__ float partial_result[N_THREADS_SEMI][N_THREADS_SEMI][N_THREADS_SEMI];
    if (threadIdx.z < N_THREADS_SEMI) {
        partial_result[threadIdx.z][threadIdx.y][threadIdx.x] = 0.0;
    }
    __syncthreads();

    const llint i0 = x3 + blockIdx.x * N_THREADS_SEMI;
    const llint j0 = y3 + blockIdx.y * N_THREADS_SEMI;
    const llint k0 = z3 + blockIdx.z * N_THREADS_SEMI;

    const llint ie = min(x4, i0+N_THREADS_SEMI);
    const llint je = min(y4, j0+N_THREADS_SEMI);
    const llint ke = min(z4, k0+N_THREADS_SEMI);

    // jk-plane moves along the i-axis
    const llint ji = j0 + threadIdx.y;
    const llint ki = k0 + threadIdx.x;
    if (ji < je && ki < ke) {
        llint i_length = ie-i0;
        int i = threadIdx.z;
        if (i < i_length + N_RADIUS) {
            float d0 = u[IDX3_l(i0+i-4,ji,ki)];
            float d1 = u[IDX3_l(i0+i-3,ji,ki)];
            float d2 = u[IDX3_l(i0+i-2,ji,ki)];
            float d3 = u[IDX3_l(i0+i-1,ji,ki)];
            float d4 = u[IDX3_l(i0+i,ji,ki)];
            if (i < i_length) {
                atomicAdd(&partial_result[i][threadIdx.y][threadIdx.x],
                    coefx_1*d3 + coefx_2*d2 + coefx_3*d1 + coefx_4*d0);
            }
            if (i >= N_RADIUS) {
                atomicAdd(&partial_result[i-N_RADIUS][threadIdx.y][threadIdx.x],
                    coefx_1*d1 + coefx_2*d2 + coefx_3*d3 + coefx_4*d4);
            }
        }
    }

    // ik-plane moves along the j-axis
    const llint ij = i0 + threadIdx.y;
    const llint kj = k0 + threadIdx.x;
    if (ij < ie && kj < ke) {
        llint j_length = je-j0;
        int j = threadIdx.z;
        if (j < j_length + N_RADIUS) {
            float d0 = u[IDX3_l(ij,j0+j-4,kj)];
            float d1 = u[IDX3_l(ij,j0+j-3,kj)];
            float d2 = u[IDX3_l(ij,j0+j-2,kj)];
            float d3 = u[IDX3_l(ij,j0+j-1,kj)];
            float d4 = u[IDX3_l(ij,j0+j,kj)];
            if (j < j_length) {
                atomicAdd(&partial_result[threadIdx.y][j][threadIdx.x],
                    coefy_1*d3 + coefy_2*d2 + coefy_3*d1 + coefy_4*d0);
            }
            if (j >= N_RADIUS) {
                atomicAdd(&partial_result[threadIdx.y][j-N_RADIUS][threadIdx.x],
                    coefy_1*d1 + coefy_2*d2 + coefy_3*d3 + coefy_4*d4);
            }
        }
    }

    // ij-plane moves along the k-axis
    const llint ik = i0 + threadIdx.y;
    const llint jk = j0 + threadIdx.x;
    if (ik < ie && jk < je) {
        llint k_length = ke-k0;
        int k = threadIdx.z;
        if (k < k_length + N_RADIUS) {
            float d0 = u[IDX3_l(ik,jk,k0+k-4)];
            float d1 = u[IDX3_l(ik,jk,k0+k-3)];
            float d2 = u[IDX3_l(ik,jk,k0+k-2)];
            float d3 = u[IDX3_l(ik,jk,k0+k-1)];
            float d4 = u[IDX3_l(ik,jk,k0+k)];

            if (k < k_length) {
                atomicAdd(&partial_result[threadIdx.y][threadIdx.x][k],
                    coefz_1*d3 + coefz_2*d2 + coefz_3*d1 + coefz_4*d0);
            }

            __syncthreads();

            if (k >= N_RADIUS) {
                float lap = coef0*d0
                          + coefz_1*d1
                          + coefz_2*d2
                          + coefz_3*d3
                          + coefz_4*d4
                          + partial_result[threadIdx.y][threadIdx.x][k-N_RADIUS];

                llint kk = k0 + k - N_RADIUS;

                const float s_eta_c = eta[IDX3_eta1(ik,jk,kk)];

                v[IDX3_l(ik,jk,kk)] = __fdiv_rn(
                    __fmaf_rn(
                        __fmaf_rn(2.f, s_eta_c,
                            __fsub_rn(2.f,
                                __fmul_rn(s_eta_c, s_eta_c)
                            )
                        ),
                        d0,
                        __fmaf_rn(
                            vp[IDX3(ik,jk,kk)],
                            __fadd_rn(lap, phi[IDX3(ik,jk,kk)]),
                            -v[IDX3_l(ik,jk,kk)]
                        )
                    ),
                    __fmaf_rn(2.f, s_eta_c, 1.f)
                );

                phi[IDX3(ik,jk,kk)] = __fdiv_rn(
                        __fsub_rn(
                            phi[IDX3(ik,jk,kk)],
                            __fmaf_rn(
                            __fmul_rn(
                                __fsub_rn(eta[IDX3_eta1(ik+1,jk,kk)], eta[IDX3_eta1(ik-1,jk,kk)]),
                                __fsub_rn(u[IDX3_l(ik+1,jk,kk)], u[IDX3_l(ik-1,jk,kk)])
                            ), hdx_2,
                            __fmaf_rn(
                            __fmul_rn(
                                __fsub_rn(eta[IDX3_eta1(ik,jk+1,kk)], eta[IDX3_eta1(ik,jk-1,kk)]),
                                __fsub_rn(u[IDX3_l(ik,jk+1,kk)], u[IDX3_l(ik,jk-1,kk)])
                            ), hdy_2,
                            __fmul_rn(
                                __fmul_rn(
                                    __fsub_rn(eta[IDX3_eta1(ik,jk,kk+1)], eta[IDX3_eta1(ik,jk,kk-1)]),
                                    __fsub_rn(u[IDX3_l(ik,jk,kk+1)], u[IDX3_l(ik,jk,kk-1)])
                                ),
                            hdz_2)
                            ))
                        )
                    ,
                    __fadd_rn(1.f, s_eta_c)
                );
            }
        }
    }
}

__global__ void kernel_add_source_kernel(float *g_u, llint idx, float source) {
    g_u[idx] += source;
}

extern "C" void target(
    uint nsteps, double *time_kernel,
    llint nx, llint ny, llint nz,
    llint x1, llint x2, llint x3, llint x4, llint x5, llint x6,
    llint y1, llint y2, llint y3, llint y4, llint y5, llint y6,
    llint z1, llint z2, llint z3, llint z4, llint z5, llint z6,
    llint lx, llint ly, llint lz,
    llint sx, llint sy, llint sz,
    float hdx_2, float hdy_2, float hdz_2,
    const float *__restrict__ coefx, const float *__restrict__ coefy, const float *__restrict__ coefz,
    float *__restrict__ u, const float *__restrict__ v, const float *__restrict__ vp,
    const float *__restrict__ phi, const float *__restrict__ eta, const float *__restrict__ source
) {
    struct timespec start, end;

    const llint size_u = (nx + 2 * lx) * (ny + 2 * ly) * (nz + 2 * lz);
    const llint size_v = size_u;
    const llint size_phi = nx*ny*nz;
    const llint size_vp = size_phi;
    const llint size_eta = (nx+2)*(ny+2)*(nz+2);

    const llint size_u_ext = ((((nx+N_THREADS_SEMI-1) / N_THREADS_SEMI + 1) * N_THREADS_SEMI) + 2 * lx)
                           * ((((ny+N_THREADS_SEMI-1) / N_THREADS_SEMI + 1) * N_THREADS_SEMI) + 2 * ly)
                           * ((((nz+N_THREADS_SEMI-1) / N_THREADS_SEMI + 1) * N_THREADS_SEMI) + 2 * lz);

    float *d_u, *d_v, *d_vp, *d_phi, *d_eta;
    cudaMalloc(&d_u, sizeof(float) * size_u_ext);
    cudaMalloc(&d_v, sizeof(float) * size_u_ext);
    cudaMalloc(&d_vp, sizeof(float) * size_vp);
    cudaMalloc(&d_phi, sizeof(float) * size_phi);
    cudaMalloc(&d_eta, sizeof(float) * size_eta);

    cudaMemcpy(d_u, u, sizeof(float) * size_u, cudaMemcpyHostToDevice);
    cudaMemcpy(d_v, v, sizeof(float) * size_v, cudaMemcpyHostToDevice);
    cudaMemcpy(d_vp, vp, sizeof(float) * size_vp, cudaMemcpyHostToDevice);
    cudaMemcpy(d_phi, phi, sizeof(float) * size_phi, cudaMemcpyHostToDevice);
    cudaMemcpy(d_eta, eta, sizeof(float) * size_eta, cudaMemcpyHostToDevice);

    const llint xmin = 0; const llint xmax = nx;
    const llint ymin = 0; const llint ymax = ny;

    dim3 threadsPerBlock(N_THREADS_SEMI, N_THREADS_SEMI, N_THREADS_SEMI+N_RADIUS);

    int num_streams = 7;
    cudaStream_t streams[num_streams];
    for (int i = 0; i < num_streams; i++) {
        cudaStreamCreate(&(streams[i]));
    }

    const uint npo = 100;
    for (uint istep = 1; istep <= nsteps; ++istep) {
        clock_gettime(CLOCK_REALTIME, &start);

        dim3 n_block_front(
            (nx+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (ny+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z2-z1+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_pml_3d_kernel<<<n_block_front, threadsPerBlock, 0, streams[1]>>>(nx,ny,nz,
            xmin,xmax,ymin,ymax,z1,z2,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        dim3 n_block_top(
            (nx+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (y2-y1+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z4-z3+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_pml_3d_kernel<<<n_block_top, threadsPerBlock, 0, streams[2]>>>(nx,ny,nz,
            xmin,xmax,y1,y2,z3,z4,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        dim3 n_block_left(
            (x2-x1+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (y4-y3+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z4-z3+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_pml_3d_kernel<<<n_block_left, threadsPerBlock, 0, streams[3]>>>(nx,ny,nz,
            x1,x2,y3,y4,z3,z4,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        dim3 n_block_center(
            (x4-x3+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (y4-y3+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z4-z3+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_inner_3d_kernel<<<n_block_center, threadsPerBlock, 0, streams[0]>>>(nx,ny,nz,
            x3,x4,y3,y4,z3,z4,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        dim3 n_block_right(
            (x6-x5+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (y4-y3+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z4-z3+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_pml_3d_kernel<<<n_block_right, threadsPerBlock, 0, streams[4]>>>(nx,ny,nz,
            x5,x6,y3,y4,z3,z4,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        dim3 n_block_bottom(
            (nx+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (y6-y5+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z4-z3+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_pml_3d_kernel<<<n_block_bottom, threadsPerBlock, 0, streams[5]>>>(nx,ny,nz,
            xmin,xmax,y5,y6,z3,z4,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        dim3 n_block_back(
            (nx+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (ny+N_THREADS_SEMI-1) / N_THREADS_SEMI,
            (z6-z5+N_THREADS_SEMI-1) / N_THREADS_SEMI);
        target_pml_3d_kernel<<<n_block_back, threadsPerBlock, 0, streams[6]>>>(nx,ny,nz,
            xmin,xmax,ymin,ymax,z5,z6,
            lx,ly,lz,
            hdx_2, hdy_2, hdz_2,
            coefx[0]+coefy[0]+coefz[0],
            coefx[1], coefx[2], coefx[3], coefx[4],
            coefy[1], coefy[2], coefy[3], coefy[4],
            coefz[1], coefz[2], coefz[3], coefz[4],
            d_u, d_v, d_vp,
            d_phi, d_eta);

        for (int i = 0; i < num_streams; i++) {
            cudaStreamSynchronize(streams[i]);
        }

        kernel_add_source_kernel<<<1, 1>>>(d_v, IDX3_l(sx,sy,sz), source[istep]);
        clock_gettime(CLOCK_REALTIME, &end);
        *time_kernel += (end.tv_sec  - start.tv_sec) +
                        (double)(end.tv_nsec - start.tv_nsec) / 1.0e9;

        float *t = d_u;
        d_u = d_v;
        d_v = t;

        // Print out
        if (istep % npo == 0) {
            printf("time step %u / %u\n", istep, nsteps);
        }
    }


    for (int i = 0; i < num_streams; i++) {
        cudaStreamDestroy(streams[i]);
    }


    cudaMemcpy(u, d_u, sizeof(float) * size_u, cudaMemcpyDeviceToHost);

    cudaFree(d_u);
    cudaFree(d_v);
    cudaFree(d_vp);
    cudaFree(d_phi);
    cudaFree(d_eta);
}

