require "spec"
require "llvm"

{% unless LibLLVM::IS_LT_150 %}
  describe LLVM::Blake3 do
    it "hashes the BLAKE3 test inputs" do
      LLVM::Blake3.hexdigest(Bytes.empty).should eq("af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262")
      LLVM::Blake3.hexdigest("abc".to_slice).should eq("6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85")
    end

    it "hashes content added in pieces as the whole content" do
      content = Bytes.new(200_000) { |index| (index % 251).to_u8 }
      hasher = LLVM::Blake3.new
      hasher.update(content[0, 1]).update(content[1, 70_000]).update(content[70_001, 129_999])
      hasher.hexfinal.should eq(LLVM::Blake3.hexdigest(content))
      hasher.hexfinal.should_not eq(LLVM::Blake3.hexdigest(content[0, 199_999]))
    end
  end
{% end %}
