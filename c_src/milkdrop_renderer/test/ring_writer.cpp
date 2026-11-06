#include "ring_writer.h"

#include "pcm_tap_writer.h"

namespace {

class Impl : public RingWriter {
public:
    explicit Impl(std::unique_ptr<pcm_tap::Writer> w) : w_(std::move(w)) {}
    void commit(uint64_t stream, uint32_t rate, const int16_t* stereo, uint32_t frames,
                int64_t t_end_us) override {
        w_->commit(stream, rate, stereo, frames, t_end_us);
    }
    void end_stream() override { w_->end_stream(); }

private:
    std::unique_ptr<pcm_tap::Writer> w_;
};

}  // namespace

std::unique_ptr<RingWriter> RingWriter::open(const std::string& path) {
    std::string err;
    auto w = pcm_tap::Writer::open(path, err);
    if (!w) return nullptr;
    return std::make_unique<Impl>(std::move(w));
}
