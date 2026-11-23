require "../spec_helper"

describe Crystal::CAllocator do
  {% if flag?(:darwin) || (flag?(:linux) && flag?(:gnu)) %}
    it "counts the bytes handed out by malloc" do
      before = Crystal::CAllocator.bytes_in_use
      block = LibC.malloc(64 * 1024 * 1024)
      begin
        Crystal::CAllocator.bytes_in_use.should be >= before + 64 * 1024 * 1024
        Crystal::CAllocator.bytes_allocated.should be >= Crystal::CAllocator.bytes_in_use
      ensure
        LibC.free(block)
      end
    end
  {% end %}

  it "returns free memory to the OS without losing what is still in use" do
    block = LibC.malloc(1024).as(UInt8*)
    block.value = 42_u8
    Crystal::CAllocator.return_free_memory
    block.value.should eq(42_u8)
    LibC.free(block)
  end
end
