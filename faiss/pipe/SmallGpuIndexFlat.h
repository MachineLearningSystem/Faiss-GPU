/**
 * Copyright (c) zili zhang & fangyue liu @PKU.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#pragma once

#include <faiss/pipe/SmallGpuIndex.h>
#include <memory>

namespace faiss {

struct IndexFlat;
struct IndexFlatL2;
struct IndexFlatIP;

} // namespace faiss

namespace faiss {
namespace gpu {

class FlatIndex;

struct SmallGpuIndexFlatConfig : public SmallGpuIndexConfig {
    inline SmallGpuIndexFlatConfig() : useFloat16(false), storeTransposed(false) {}

    /// Whether or not data is stored as float16
    bool useFloat16;

    /// Whether or not data is stored (transparently) in a transposed
    /// layout, enabling use of the NN GEMM call, which is ~10% faster.
    /// This will improve the speed of the flat index, but will
    /// substantially slow down any add() calls made, as all data must
    /// be transposed, and will increase storage requirements (we store
    /// data in both transposed and non-transposed layouts).
    bool storeTransposed;
};

/// Wrapper around the GPU implementation that looks like
/// faiss::IndexFlat; copies over centroid data from a given
/// faiss::IndexFlat
class SmallGpuIndexFlat : public SmallGpuIndex {
   public:
    /// Construct from a pre-existing faiss::IndexFlat instance, copying
    /// data over to the given GPU
    SmallGpuIndexFlat(
            GpuResourcesProvider* provider,
            const faiss::IndexFlat* index,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    SmallGpuIndexFlat(
            std::shared_ptr<GpuResources> resources,
            const faiss::IndexFlat* index,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    /// Construct an empty instance that can be added to
    SmallGpuIndexFlat(
            GpuResourcesProvider* provider,
            int dims,
            faiss::MetricType metric,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    SmallGpuIndexFlat(
            std::shared_ptr<GpuResources> resources,
            int dims,
            faiss::MetricType metric,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    ~SmallGpuIndexFlat() override;

    /// Initialize ourselves from the given CPU index; will overwrite
    /// all data in ourselves
    void copyFrom(const faiss::IndexFlat* index);

    /// Copy ourselves to the given CPU index; will overwrite all data
    /// in the index instance
    void copyTo(faiss::IndexFlat* index) const;

    /// Returns the number of vectors we contain
    size_t getNumVecs() const;

    /// Clears all vectors from this index
    void reset() override;

    /// This index is not trained, so this does nothing
    void train(Index::idx_t n, const float* x) override;

    /// Overrides to avoid excessive copies
    void add(Index::idx_t, const float* x) override;

    /// Reconstruction methods; prefer the batch reconstruct as it will
    /// be more efficient
    void reconstruct(Index::idx_t key, float* out) const override;

    /// Batch reconstruction method
    void reconstruct_n(Index::idx_t i0, Index::idx_t num, float* out)
            const override;

    /// Compute residual
    void compute_residual(const float* x, float* residual, Index::idx_t key)
            const override;

    /// Compute residual (batch mode)
    void compute_residual_n(
            Index::idx_t n,
            const float* xs,
            float* residuals,
            const Index::idx_t* keys) const override;

    /// For internal access
    inline FlatIndex* getGpuData() {
        return data_.get();
    }

   protected:
    /// Flat index does not require IDs as there is no storage available for
    /// them
    bool addImplRequiresIDs_() const override;

    /// Called from SmallGpuIndex for add
    void addImpl_(int n, const float* x, const Index::idx_t* ids) override;

    /// Called from SmallGpuIndex for search
    void searchImpl_(
            int n,
            const float* x,
            int k,
            float* distances,
            Index::idx_t* labels) const override;

   protected:
    /// Our configuration options
    const SmallGpuIndexFlatConfig flatConfig_;

    /// Holds our GPU data containing the list of vectors
    std::unique_ptr<FlatIndex> data_;
};

/// Wrapper around the GPU implementation that looks like
/// faiss::IndexFlatL2; copies over centroid data from a given
/// faiss::IndexFlat
class SmallGpuIndexFlatL2 : public SmallGpuIndexFlat {
   public:
    /// Construct from a pre-existing faiss::IndexFlatL2 instance, copying
    /// data over to the given GPU
    SmallGpuIndexFlatL2(
            GpuResourcesProvider* provider,
            faiss::IndexFlatL2* index,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    SmallGpuIndexFlatL2(
            std::shared_ptr<GpuResources> resources,
            faiss::IndexFlatL2* index,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    /// Construct an empty instance that can be added to
    SmallGpuIndexFlatL2(
            GpuResourcesProvider* provider,
            int dims,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    SmallGpuIndexFlatL2(
            std::shared_ptr<GpuResources> resources,
            int dims,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    /// Initialize ourselves from the given CPU index; will overwrite
    /// all data in ourselves
    void copyFrom(faiss::IndexFlat* index);

    /// Copy ourselves to the given CPU index; will overwrite all data
    /// in the index instance
    void copyTo(faiss::IndexFlat* index);
};

/// Wrapper around the GPU implementation that looks like
/// faiss::IndexFlatIP; copies over centroid data from a given
/// faiss::IndexFlat
class SmallGpuIndexFlatIP : public SmallGpuIndexFlat {
   public:
    /// Construct from a pre-existing faiss::IndexFlatIP instance, copying
    /// data over to the given GPU
    SmallGpuIndexFlatIP(
            GpuResourcesProvider* provider,
            faiss::IndexFlatIP* index,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    SmallGpuIndexFlatIP(
            std::shared_ptr<GpuResources> resources,
            faiss::IndexFlatIP* index,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    /// Construct an empty instance that can be added to
    SmallGpuIndexFlatIP(
            GpuResourcesProvider* provider,
            int dims,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    SmallGpuIndexFlatIP(
            std::shared_ptr<GpuResources> resources,
            int dims,
            SmallGpuIndexFlatConfig config = SmallGpuIndexFlatConfig());

    /// Initialize ourselves from the given CPU index; will overwrite
    /// all data in ourselves
    void copyFrom(faiss::IndexFlat* index);

    /// Copy ourselves to the given CPU index; will overwrite all data
    /// in the index instance
    void copyTo(faiss::IndexFlat* index);
};

} // namespace gpu
} // namespace faiss
