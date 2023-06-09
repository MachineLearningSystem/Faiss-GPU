/**
 * Copyright (c) zili zhang & fangyue liu @PKU.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#include <algorithm>
#include <cmath>
#include <sys/time.h>
#include <iostream>
#include <string.h>
#include <set>

#include <faiss/pipe/NaiveScheduler.h>
#include <faiss/gpu/impl/DistanceUtils.cuh>

namespace faiss {
namespace gpu{

const int wait_interval_naive = 5 * 1000; // 5 ms

double elapsed_naive() {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec + tv.tv_usec * 1e-6;
}

struct Param_Naive{
    NaiveScheduler* sche;
    IndexIVFPipe* index;
    int clunum;
    std::vector<int> group;
    int k;
    int device;
};

// Thread function: computation
void *computation_naive(void *arg){
    Param_Naive* param = (Param_Naive *)arg;
    double compu_time = 0.;
    double t, tt;

    // Destruct the param
    PipeCluster* pc = param->sche->pc_;
    PipeGpuResources* pgr = param->sche->pgr_;
    int k = param->k;

    DeviceScope scope(param->device);
    // Handle the params
    int *matrix;
    int *queryIds;
    auto t0 = elapsed_naive();
    int dataCnt;
    auto shape = param->sche->genematrix(&matrix, &queryIds, param->group, &dataCnt);
    if(param->sche->verbose)
        printf("debug : tranpose time %.3f\n", (elapsed_naive() - t0)*1000);

    // Prepare the data
    std::vector<void*> ListDataP_vec(param->clunum);
    std::vector<void*> ListIndexP_vec(param->clunum);
    std::vector<int> ListLength_vec(param->clunum);

    // Noneed mutex here
    for(int i = 0; i < param->clunum; i++) {
        int cluid = param->group[i];
        ListDataP_vec[i] = param->sche->address[cluid];
        ListIndexP_vec[i] = (void *)((float*)(ListDataP_vec[i]) + 
                pc->d * pc->BCluSize[cluid]);
        ListLength_vec[i] = pc->BCluSize[cluid];
    }

    // Only one com thread is allowed in
    pthread_mutex_lock(&(pc->com_mutex));
    pthread_mutex_lock(&(pc->resource_mutex));
    t = elapsed_naive();
    int idx = param->sche->com_index++;
    param->sche->queries_ids[idx] = queryIds;
    param->sche->queries_num[idx] = shape.first;
    // param->sche->max_quries_num = std::max(param->sche->max_quries_num, shape.first)
    auto exec_stream = pgr->getExecuteStream(param->device);
    auto d2h_stream = pgr->getCopyD2HStream(param->device);
    // auto d2h_stream = pgr->getCopyH2DStream(param->device);

    // Create the Tensors
    for (int i = 0; i < shape.first; i++){
        param->sche->cnt_per_query[queryIds[i]]++;
        param->sche->max_split = std::max(param->sche->max_split, 
            param->sche->cnt_per_query[queryIds[i]]);
    }

    param->sche->dis_buffer[idx] = 
        new PipeTensor<float, 2, true>({(int)shape.first, (int)k}, pc);
    param->sche->dis_buffer[idx]->setResources(pc, pgr);
    param->sche->dis_buffer[idx]->reserve();

    param->sche->ids_buffer[idx] = 
        new PipeTensor<int, 2, true>({(int)shape.first, (int)k}, pc);
    param->sche->ids_buffer[idx]->setResources(pc, pgr);
    param->sche->ids_buffer[idx]->reserve();

    pthread_mutex_lock(&(param->sche->preemption_mutex));
    param->sche->preemption = false;
    pthread_mutex_unlock(&(param->sche->preemption_mutex));

    PipeTensor<void*, 1, true>* ListDataP_ = 
        new PipeTensor<void*, 1, true>({param->clunum}, pc);
    ListDataP_->copyFrom(ListDataP_vec, exec_stream);
    ListDataP_->setResources(pc, pgr);
    ListDataP_->memh2d(exec_stream);

    PipeTensor<void*, 1, true>*  ListIndexP_ =
        new PipeTensor<void*, 1, true>({param->clunum}, pc);
    ListIndexP_->copyFrom(ListIndexP_vec, exec_stream);
    ListIndexP_->setResources(pc, pgr);
    ListIndexP_->memh2d(exec_stream);

    PipeTensor<int, 1, true>* ListLength_ = 
        new PipeTensor<int, 1, true>({param->clunum}, pc);
    ListLength_->copyFrom(ListLength_vec, exec_stream);
    ListLength_->setResources(pc, pgr);
    ListLength_->memh2d(exec_stream);

    PipeTensor<int, 1, true>* queryids_gpu = 
        new PipeTensor<int, 1, true>({(int)shape.first}, pc);
    queryids_gpu->copyFrom(queryIds, exec_stream);
    queryids_gpu->setResources(pc, pgr);
    queryids_gpu->memh2d(exec_stream);

    PipeTensor<int, 2, true>* query_cluster_matrix_gpu =
        new PipeTensor<int, 2, true>({(int)shape.first, (int)shape.second}, pc);
    query_cluster_matrix_gpu->copyFrom(matrix, exec_stream);
    query_cluster_matrix_gpu->setResources(pc, pgr);
    query_cluster_matrix_gpu->memh2d(exec_stream);

    pthread_mutex_lock(&(param->sche->preemption_mutex));
    param->sche->preemption = true;
    pthread_mutex_unlock(&(param->sche->preemption_mutex));

    tt = elapsed_naive();
    if(param->sche->verbose)
        printf("debug : Tensor time %.3f\n", (tt - t)*1000);
    // compu_time += tt - t;

    pthread_mutex_unlock(&(pc->resource_mutex));
    cudaStreamSynchronize(exec_stream);
    t = elapsed_naive();

    int split = param->sche->profiler->decideSplit(shape.first, dataCnt);

    bool dir;
    if (param->index->metric_type == MetricType::METRIC_L2) {
        L2Distance metr;
        dir = metr.kDirection;                                            
    } else if (param->index->metric_type == MetricType::METRIC_INNER_PRODUCT) {
        IPDistance metr;          
        dir = metr.kDirection;
    }

    runKernelComputeReduce(
            pc->d,
            k,
            shape.first,
            shape.second,
            *queryids_gpu,
            *(param->sche->queries_gpu),
            *query_cluster_matrix_gpu,
            ListDataP_->devicedata(),
            param->index->ivfPipeConfig_.indicesOptions,
            ListLength_->devicedata(),
            ListIndexP_->devicedata(),
            param->index->metric_type,
            dir,
            *(param->sche->dis_buffer[idx]),
            *(param->sche->ids_buffer[idx]),
            pc,
            pgr,
            param->device,
            split);
    
    cudaStreamSynchronize(exec_stream);

    param->sche->dis_buffer[idx]->memd2h(d2h_stream);
    param->sche->dis_buffer[idx]->memd2h(d2h_stream);

    // Delete the allocated Tensor in order
    delete query_cluster_matrix_gpu;
    delete queryids_gpu;
    delete ListLength_;
    delete ListIndexP_;
    delete ListDataP_;

    //dataCnt = shape.first * shape.second;
    tt = elapsed_naive();
    float real_com = tt - t;
    compu_time += real_com;

    param->sche->com_time += compu_time;

    pthread_mutex_unlock(&(pc->com_mutex));

    // Change page info
    pthread_mutex_lock(&(pc->resource_mutex));

    cudaFree(param->sche->address[param->group[0]]);

    pthread_mutex_unlock(&(pc->resource_mutex));


    delete[] matrix;
    // delete[] queryIds;

    return((void *)0);
}

NaiveScheduler::NaiveScheduler(IndexIVFPipe* index, PipeCluster* pc, PipeGpuResources* pgr, int bcluster_cnt_,
        int* bcluster_list_, int* query_per_bcluster_, int maxquery_per_bcluster_,
        int* bcluster_query_matrix_, PipeProfiler* profiler_,
        int queryMax_, int clusMax_, bool free_) 
        : index_(index), pc_(pc), pgr_(pgr), bcluster_cnt(bcluster_cnt_), profiler(profiler_),
        bcluster_list(bcluster_list_), query_per_bcluster(query_per_bcluster_), \
        maxquery_per_bcluster(maxquery_per_bcluster_), \
        bcluster_query_matrix(bcluster_query_matrix_), free(free_),\
        queryMax(queryMax_), clusMax(clusMax_), num_group(-1){
            DeviceScope *scope;
            if(index != nullptr)
                scope = new DeviceScope(index->ivfPipeConfig_.device);
            reorder_list.resize(bcluster_cnt);

            reorder();
            //nonReorder();

            group();

            FAISS_ASSERT(num_group > 0);
            // Initialize the computation threads
            pc_->com_threads.resize(num_group);

            if(scope != nullptr){
                delete scope;
            }

        }

NaiveScheduler::NaiveScheduler(IndexIVFPipe* index, PipeCluster* pc, PipeGpuResources* pgr,
            int n, float *xq, int k, float *dis, int *label, bool free_)
            : index_(index), pc_(pc), pgr_(pgr), profiler(index->profiler), batch_size(n){
                DeviceScope *scope;
                if(index != nullptr)
                    scope = new DeviceScope(index->ivfPipeConfig_.device);

                pthread_mutex_init(&preemption_mutex, 0);

                int actual_nprobe;
                int maxbcluster_per_query;
                auto t0 = elapsed_naive();
                index->sample_list(n, xq, &coarse_dis, &ori_idx,\
                    &bcluster_per_query, &actual_nprobe, &query_bcluster_matrix, &maxbcluster_per_query,\
                    &bcluster_cnt, &bcluster_list, &query_per_bcluster, &maxquery_per_bcluster,\
                    &bcluster_query_matrix);
                auto t1 = elapsed_naive();
                if(verbose)
                    printf("Sample Time: %.3f ms\n", (t1 - t0)*1000);
                t0 = t1;
                
                reorder_list.resize(bcluster_cnt);

                reorder();
                //nonReorder();
                t1 = elapsed_naive();
                if(verbose)
                    printf("Reorder Time: %.3f ms\n", (t1 - t0)*1000);
                reorder_time += (t1 - t0)*1000;
                t0 = t1;

                group();
                t1 = elapsed_naive();
                if(verbose)
                    printf("Group Time: %.3f ms\n", (t1 - t0)*1000);
                group_time = (t1 - t0)*1000;
                t0 = t1;

                // deubg
                if(verbose){
                    printf("----Demo group----\n");
                    for(int i = 0; i < groups.size(); i++){
                        printf("%d ", groups[i]);
                    }
                    printf("\n");
                }
                
                FAISS_ASSERT(num_group > 0);
                // Initialize the computation threads
                pc_->com_threads.resize(num_group);

                process(n, xq, k, dis, label);

                t1 = elapsed_naive();
                printf("Process Time: %.3f ms\n", (t1 - t0)*1000);
                t0 = t1;

                if(scope != nullptr){
                    delete scope;
                }    

            }

NaiveScheduler::~NaiveScheduler(){
    DeviceScope* scope;
    if(index_ != nullptr){
        scope = new DeviceScope(index_->ivfPipeConfig_.device);
    }
    // Free the input resource
    if(free){
        delete[] coarse_dis;
        delete[] ori_idx;
        delete[] bcluster_per_query;
        delete[] query_bcluster_matrix;

        delete[] bcluster_list;
        delete[] query_per_bcluster;
        delete[] bcluster_query_matrix;
    }

    if (queries_gpu != nullptr){
        delete queries_gpu;
    }

    pthread_mutex_destroy(&preemption_mutex);

    // Free the PipeTensor in order
    if(scope != nullptr){
        delete scope;
    }
}

void NaiveScheduler::reorder(){
    double t0 , t1;
    // The new order list consists of two components:
    // 1. clusters already in GPU  2. sorted cluster according 
    // to reference number in descending order
    std::vector<std::pair<int, int> > temp_list(bcluster_cnt);
    std::vector<std::pair<int, int> > lru_list(bcluster_cnt);
    int index = 0;
    int index2 = 0;
    // Part 1
    for (int i = 0; i < bcluster_cnt; i++){
        int cluid = bcluster_list[i];
        // Initialize the map
        reversemap[cluid] = i;

        bool che = false;
        if (pc_ != nullptr)
            che = pc_->readonDevice(cluid);
        
        if (che){
            lru_list[index].second = cluid;
            lru_list[index++].first = pc_->readGlobalCount(cluid);
        }
        else {
            temp_list[index2].second = cluid;
            temp_list[index2++].first = query_per_bcluster[i];
        }
    }

    FAISS_ASSERT(index + index2 == bcluster_cnt);

    // Part 2
    t0 = elapsed_naive();
    // multi_sort<int, int> (temp_list.data(), index2);
    std::sort(temp_list.begin(), temp_list.begin() + index2, Com<int,int>);
    // multi_sort<int, int> (lru_list.data(), index);
    std::sort(lru_list.begin(), lru_list.begin() + index, Com<int,int>);
    t1 = elapsed_naive();
    if(verbose)
        printf("Part 2 : %.3f ms\n", (t1 - t0) * 1000);

    // for (int i = 0; i < 20; i++){
    //     printf("%d %d\n", temp_list[i].second, temp_list[i].first);
    // }

    // Merge the two parts
    for (int i = index; i < bcluster_cnt; i++)
        reorder_list[i] = temp_list[i - index].second;

    for (int i = 0; i < index; i++)
        reorder_list[index - i - 1] = lru_list[i].second;

    part_size = index;

    int slice = 8;

    if (batch_size > 0 && batch_size >= 128)
        slice = 8;
    else if (batch_size > 0)
        slice = 4;

    grain = (bcluster_cnt - part_size) / slice;

    grain = (grain == 0 ? 1 : grain);

    // grain = 1;
    if(verbose)
        printf("debug out reorder: %d %d\n", int(reorder_list.size()), grain);

}

void NaiveScheduler::nonReorder(){
    for (int i = 0; i < bcluster_cnt; i++){
        int cluid = bcluster_list[i];
        reversemap[cluid] = i;
        reorder_list[i] = cluid;
    }

    part_size = 0;

    int slice = 8;

    if (batch_size > 0 && batch_size >= 128)
        slice = 8;
    else if (batch_size > 0)
        slice = 4;

    grain = (bcluster_cnt - part_size) / slice;

    grain = (grain == 0 ? 1 : grain);

    // grain = 1;
    if(verbose)
        printf("debug out reorder: %d %d\n", int(reorder_list.size()), grain);
}

void NaiveScheduler::group(){
    canv = 0;

    FAISS_ASSERT(grain > 0);

    pipelinegroup opt;

    int n = reorder_list.size();

    // The 4 here is hyperparamter
    // Each group size can not overstep this value
    if (pgr_)
        max_size = pgr_->pageNum_ - part_size + part_size / 4;
    else
        max_size = n - part_size + part_size / 4;

    grain = std::min(grain, max_size);
    if(verbose)
        printf("debug: grain %d, part size %d\n", grain, part_size);

    if (part_size != 0) {
        int pre = part_size / 4;
        if (pre == 0){
            groups.push_back(part_size);
        }
        else {
            groups.push_back(part_size / 4);
            groups.push_back(part_size);
        }
    }

    //Check if all clusters are resident on device
    int temp = groups.size();
    if (temp > 0 && groups[temp - 1] == n){
        num_group = temp;
        return;
    }

    float delay = measure_com(part_size/4, part_size);
    int f1 = part_size + 1;

    // prune 1
    for (int i = part_size + 1; i <= n; i+=1){
        float trantime = measure_tran(i - part_size);
        if (trantime < delay)
            f1 = i;
        else
            break;
        if (i - part_size >= max_size)
            break;
    }

    for (int i = f1; i <= n; i+=grain){
        if (i - part_size > max_size)
            break;
        // prune 2
        float totaltime;
        float delaytime;
        if (!opt.content.empty()){
            float tran1 = measure_tran(i - part_size);
            float tran2 = measure_tran(n - i);
            float trantime = tran1 + tran2;
            float interval = delay - tran1;
            interval = interval > 0 ? interval : 0;
            delaytime = measure_com(part_size, i) + interval;
            totaltime = std::max(tran1, delay) + delaytime - interval;
            float comtime = totaltime + measure_com(i, n);
            float time = std::max(comtime, trantime);
            if (time >= opt.time)
                continue;
        }
        else{
            float tran1 = measure_tran(i - part_size);
            float interval = delay - tran1;
            interval = interval > 0 ? interval : 0;
            delaytime = measure_com(part_size, i) + interval;
            totaltime = std::max(tran1, delay) + delaytime - interval;
        }
        // recursively find rest groups
        pipelinegroup first_gr;
        first_gr.content.push_back(i);
        first_gr.time = totaltime;
        first_gr.delay = delaytime;
        pipelinegroup rest = group(i, totaltime, delaytime, 1);
        auto size = first_gr.content.size();
        first_gr.content.resize(size + rest.content.size());
        memcpy (first_gr.content.data() + size, rest.content.data(), sizeof(int) * rest.content.size());
        first_gr.time = rest.time;
        if (opt.time > first_gr.time)
            opt = first_gr;
    }

    std::cout << "OPT: " << opt.time << "ms \n";

    auto size = groups.size();
    groups.resize(size + opt.content.size());
    memcpy(groups.data() + size,  opt.content.data(), sizeof(int) * opt.content.size());

    num_group = groups.size();

    if (groups[num_group - 1] != n){
        int end = groups[num_group - 1];
        int preend = num_group - 2 >= 0 ? groups[num_group - 2] : 0;
        if (end - preend >= max_size){
            num_group++;
            groups.push_back(n);
        }
        else
            groups[num_group - 1] = n;
    }

}

NaiveScheduler::pipelinegroup NaiveScheduler::group(int staclu, float total, float delay, int depth){
    pipelinegroup opt;
    int n = reorder_list.size();
    int f1 = staclu + grain;
    if (f1 == n + grain){
        opt.time = total;
        opt.delay = delay;
        
        canv += 1;

        if(canv % 1000000 == 0){
            printf("%d\n", canv/1000000);
        }
        return opt;
    }
    else if (f1 > n){

        float tran = measure_tran(n - staclu);
        float com = measure_com(staclu, n);

        opt.time = tran > delay ? total + tran - delay + com : total + com;

        canv += 1;

        if(canv % 1000000 == 0){
            printf("%d\n", canv/1000000);
        }
        return opt;


    }

    // prune 1
    for (int i = staclu + grain; i <= n; i+=1){
        float trantime = measure_tran(i - staclu);
        if (trantime < delay)
            f1 = i;
        else
            break;
        if (i - staclu >= max_size)
            break;
    }

    for (int i = f1; i <= n; i+=grain){
        if (i - staclu > max_size)
            break;
        // prune 2
        float totaltime;
        float delaytime;
        if (!opt.content.empty()){
            float tran1 = measure_tran(i - staclu);
            float tran2 = measure_tran(n - i);
            float trantime = tran1 + tran2;
            float interval = delay - tran1;
            interval = interval > 0 ? interval : 0;
            delaytime = measure_com(staclu, i) + interval;
            if (delay > tran1)
                totaltime = total + delaytime - interval;
            else
                totaltime = total - delay + tran1 + delaytime;
            float comtime = totaltime + measure_com(i, n);
            float time = std::max(comtime, trantime);
            if (time >= opt.time)
                continue;
        }
        else{
            float tran1 = measure_tran(i - staclu);
            float interval = delay - tran1;
            interval = interval > 0 ? interval : 0;
            delaytime = measure_com(staclu, i) + interval;
            if (delay > tran1)
                totaltime = total + delaytime - interval;
            else
                totaltime = total - delay + tran1 + delaytime;
        }
        // recursively find rest groups
        pipelinegroup first_gr;
        first_gr.content.push_back(i);
        first_gr.time = totaltime;
        first_gr.delay = delaytime;
        // std::cout << "IN " << i << " Time : " << totaltime << "ms, " << delaytime << "ms \n";
        pipelinegroup rest = group(i, totaltime, delaytime, depth + 1);
        // std::cout << "The " << i << "th OUT: ";
        // for (int j = 0; j < rest.content.size(); j++){
        //     std::cout << rest.content[j] << " ";
        // }
        // std::cout << " Time: " << rest.time << "ms \n";
        auto size = first_gr.content.size();
        first_gr.content.resize(size + rest.content.size());
        memcpy (first_gr.content.data() + size, rest.content.data(), sizeof(int) * rest.content.size());
        first_gr.time = rest.time;
        if (opt.time > first_gr.time)
            opt = first_gr;
    }

    canv += 1;

    if(canv % 1000000 == 0){
        printf("%d\n", canv/1000000);
    }
    return opt;

}

NaiveScheduler::malloc_res NaiveScheduler::gpu_malloc(size_t size){
    malloc_res res;
    void *p;
    size_t avail;
    size_t total;
    cudaMemGetInfo(&avail, &total);
    if (avail < size){
        res.valid = false;
        return res;
    }
    else{
        auto error = cudaMalloc((void **) &p, size);
        FAISS_ASSERT_FMT(
                error == cudaSuccess,
                "Failed to cuda malloc memory: %zu bytes (error %d %s)",
                size,
                (int)error,
                cudaGetErrorString(error));
        res.valid = true;
        res.pointer = p;
        return res;
    }
}

void NaiveScheduler::process(int n, float *xq, int k, float *dis, int *label){

    int device = index_->ivfPipeConfig_.device;
    auto h2d_stream = pgr_->getCopyH2DStream(device);

    queryMax = n;

    DeviceScope scope(device);
    // Create queries Tensor
    this->queries_gpu = new PipeTensor<float, 2, true>({n, this->pc_->d}, pc_);
    queries_gpu->copyFrom((float*)xq, pgr_->getExecuteStream(device));
    queries_gpu->setResources(pc_, pgr_);
    queries_gpu->memh2d(pgr_->getExecuteStream(device));

    // Initialize the buffer
    dis_buffer.resize(num_group);
    ids_buffer.resize(num_group);
    queries_ids.resize(num_group);
    queries_num.resize(num_group);
    cnt_per_query.resize(n);
    std::fill(cnt_per_query.data(), cnt_per_query.data() + n, 0);

    for (int i = 0 ; i < num_group; i++){
        int sta = (i == 0 ? 0 : groups[i-1]);
        int end = groups[i];
    }

    std::vector<Param_Naive> params(num_group);
    // loop over groups
    for (int i = 0 ; i < num_group; i++){
        int sta = (i == 0 ? 0 : groups[i-1]);
        int end = groups[i];
        
        FAISS_ASSERT(end > sta);

        // Transmission
        std::vector<int> clusters(end - sta);
        int num = 0;
        for (int j = 0; j < clusters.size(); j++){
            clusters[j] = reorder_list[sta + j];
            num++;
        }
        size_t bytes = num * pgr_->pageSize_;

        if (num > 0){
            while (true){
                pthread_mutex_lock(&(pc_->resource_mutex));
                malloc_res res = gpu_malloc(bytes);
                pthread_mutex_unlock(&(pc_->resource_mutex));
                if (res.valid){
                    auto tt0 = elapsed_naive();
                    for (int j = 0; j < num; j++){
                        int clus = clusters[j];
                        address[clus] = res.getPage(j, pgr_->pageSize_ / sizeof(float));
                        float *target = (float*)address[clus];

                        size_t vec_bytes = pc_->BCluSize[clus] * sizeof(float) * pc_->d;
                        size_t index_bytes = pc_->BCluSize[clus] * sizeof(int);
                        float *index_target = target + vec_bytes / sizeof(float);
                        cudaMemcpy((void*)target , pc_->Mem[clus],
                            vec_bytes, cudaMemcpyHostToDevice);

                        cudaMemcpy((void*)index_target , pc_->Balan_ids[clus], 
                            index_bytes, cudaMemcpyHostToDevice);
                    }
                    auto tt1 = elapsed_naive();
                    com_transmission += tt1 - tt0;
                    break;
                }
                else{
                    usleep(wait_interval_naive);
                }
            }
        }

        // Start computation
        Param_Naive *param = &(params[i]);
        param->sche = this;
        param->clunum = end - sta;
        param->group = clusters;
        param->k = k;
        param->index = this->index_;
        param->device = device;

        pthread_create(&(pc_->com_threads[i]), NULL, computation_naive, param);

    }
    for (int i = 0 ; i < num_group; i++){
        int res = pthread_join(pc_->com_threads[i], NULL);
        FAISS_ASSERT(res == 0);
    }

    // Check all exec threads
    FAISS_ASSERT(com_index == num_group);

    // Start Merge
    auto exec_stream = pgr_->getExecuteStream(device);
    PipeTensor<int, 1, true> *cnt_per_query_gpu = 
        new PipeTensor<int, 1, true>({(int)n}, this->pc_);
    cnt_per_query_gpu->copyFrom(cnt_per_query, exec_stream);
    cnt_per_query_gpu->setResources(pc_, pgr_);
    cnt_per_query_gpu->memh2d(exec_stream);

    std::vector<float*> result_distances(n * max_split);
    std::vector<int*> result_indices(n * max_split);
    std::vector<int> query_index(n);
    std::fill(query_index.data(), query_index.data() + n, 0);

    for (int i = 0; i < num_group; i++){
        int num = queries_num[i];
        for (int j = 0; j < num; j++){
            int qid = queries_ids[i][j];
            result_distances[qid * max_split + query_index[qid]] = 
                (*(dis_buffer[i]))(j).data();
            result_indices[qid * max_split + query_index[qid]] = 
                (*(ids_buffer[i]))(j).data();
            query_index[qid]++;
        }
    }

    PipeTensor<int*, 2, true>* result_indices_gpu = 
        new PipeTensor<int*, 2, true>({(int)n, max_split}, pc_);
    result_indices_gpu->copyFrom(result_indices, exec_stream);
    result_indices_gpu->setResources(pc_, pgr_);
    result_indices_gpu->memh2d(exec_stream);

    PipeTensor<float*, 2, true>* result_distances_gpu =
        new PipeTensor<float*, 2, true>({(int)n, max_split}, pc_);
    result_distances_gpu->copyFrom(result_distances, exec_stream);
    result_distances_gpu->setResources(pc_, pgr_);
    result_distances_gpu->memh2d(exec_stream);

    bool dir;
    if (index_->metric_type == MetricType::METRIC_L2) {
        L2Distance metr;
        dir = metr.kDirection;                                            
    } else if (index_->metric_type == MetricType::METRIC_INNER_PRODUCT) {
        IPDistance metr;          
        dir = metr.kDirection;
    }
    else{
        FAISS_ASSERT (false);
    }

    PipeTensor<float, 2, true>* out_distances = 
        new PipeTensor<float, 2, true>({(int)n, (int)k}, pc_);
    out_distances->setResources(pc_, pgr_);
    out_distances->reserve();                

    PipeTensor<int, 2, true> *out_indices = 
        new PipeTensor<int, 2, true>({(int)n, (int)k}, pc_);
    out_indices->setResources(pc_, pgr_);
    out_indices->reserve();

    runKernelMerge(
        *cnt_per_query_gpu,
        *result_distances_gpu,
        *result_indices_gpu,
        k,
        index_->ivfPipeConfig_.indicesOptions,
        dir,
        *out_distances,
        *out_indices,
        exec_stream);

    cudaStreamSynchronize(exec_stream);

    auto cudaStatus = cudaGetLastError();
    if (cudaStatus != cudaSuccess){
        FAISS_THROW_FMT("Kernel launch and process failed: %s\n", 
            cudaGetErrorString(cudaStatus));
    }

    auto d2h_stream = pgr_->getCopyD2HStream(device);
    out_distances->memd2h(d2h_stream);
    out_indices->memd2h(d2h_stream);
    cudaStreamSynchronize(d2h_stream);

    int bytes = n * k * sizeof(float);

    memcpy(dis, out_distances->hostdata(), bytes);
    memcpy(label, out_indices->hostdata(), bytes);

    // Delete Tensors
    delete out_indices;
    delete out_distances;
    delete result_distances_gpu;
    delete result_indices_gpu;
    delete cnt_per_query_gpu;

    for (int i = num_group - 1; i >= 0; i--){
        delete ids_buffer[i];
        delete dis_buffer[i];
        delete[] queries_ids[i];
    }

    return;

}

float NaiveScheduler::measure_tran(int num){
    if (num == 0)
        return 0.;
    
    if (profiler != nullptr) {
        return profiler->queryTran(num);
    }
    return 0.01 * num + 0.02;
}

float NaiveScheduler::measure_com(int sta, int end){
    if (sta == end)
        return 0.;

    if (profiler != nullptr) {
        int dataCnt = 0;
        for( int i = sta; i < end; i++) {
            int order = reversemap[reorder_list[i]];
            int query_num = query_per_bcluster[order];
            dataCnt += query_num;
        }
        return profiler->queryCom(dataCnt);
    }
    else {
        int dataCnt = 0;
        for( int i = sta; i < end; i++) {
            dataCnt += query_per_bcluster[reversemap[reorder_list[i]]];
        }
        return 0.0002 * (double)dataCnt + .02;
    }

}

// Remember to delete queryClusMat & queryIds to avoid memory leak !!!
std::pair<int, int> NaiveScheduler::genematrix(int **queryClusMat, int **queryIds, 
        const std::vector<int> & group, int* dataCnt){
    int groupSize = group.size();

    int maxqueryNum = maxquery_per_bcluster;
    int clusMax = pc_->bnlist;
    std::vector<int> rows(groupSize);
    for (int i = 0; i < groupSize; i++)
        rows[i] = reversemap[group[i]];
    FAISS_ASSERT(maxqueryNum > 0);

    if (groupSize > 1000000){
        transpose(bcluster_query_matrix, queryClusMat, &groupSize, &maxqueryNum, 
            queryMax, clusMax, rows, bcluster_list, queryIds, dataCnt);
    }
    else{
        transpose_single(bcluster_query_matrix, queryClusMat, &groupSize, &maxqueryNum, 
            queryMax, clusMax, rows, bcluster_list, queryIds, dataCnt);
    }

    return std::pair<int,int>(maxqueryNum, groupSize);
}

} // namespace gpu
} // namespace faiss