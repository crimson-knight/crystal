require "../../spec_helper"
require "../../digest/spec_helper"
require "crystal/digest/sha256"

describe Crystal::Digest::SHA256 do
  it_acts_as_digest_algorithm Crystal::Digest::SHA256

  [
    {"", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU="},
    {"abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3qctBD/YfIAFa0="},
    {"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1", "JI1qYdIGOLjlwCaTDD5gOaM85Flk/yFn9uzt1BnbBsE="},
    {"The quick brown fox jumps over the lazy dog", "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592", "16j7swfXgJRpypq8sAguT41WUeRtPNt2LQLQvzfJ5ZI="},
    {"0123456701234567012345670123456701234567012345670123456701234567", "8182cadb21af0e37c06414ece08e19c65bdb22c396d48ba7341012eea9ffdfdd", "gYLK2yGvDjfAZBTs4I4ZxlvbIsOW1IunNBAS7qn/390="},
    {"fooø", "df81eea14671ce970fb1052e9f5dd6dbda652ed37423ed3624120ec1534784a7", "34HuoUZxzpcPsQUun13W29plLtN0I+02JBIOwVNHhKc="},
    # 55 bytes: the padding and the length still fit in the last block.
    {"0123456789012345678901234567890123456789012345678901234", "f34d5a0f80c0cbf84c8c0b90218c22637abd199965249da736a20143c8c9c9d9", "801aD4DAy/hMjAuQIYwiY3q9GZllJJ2nNqIBQ8jJydk="},
  ].each do |(string, hexstring, base64digest)|
    it "does digest for #{string.inspect}" do
      Crystal::Digest::SHA256.digest(string).hexstring.should eq(hexstring)
    end

    it "resets" do
      digest = Crystal::Digest::SHA256.new
      digest.update string
      digest.final.hexstring.should eq(hexstring)

      digest.reset
      digest.update string
      digest.final.hexstring.should eq(hexstring)
    end

    it "does digest for #{string.inspect} in a block" do
      bytes = Crystal::Digest::SHA256.digest do |context|
        string.each_char do |character|
          context.update character.to_s
        end
      end

      bytes.hexstring.should eq(hexstring)
    end

    it "does base64digest for #{string.inspect}" do
      Crystal::Digest::SHA256.base64digest(string).should eq(base64digest)
    end
  end

  it "does digest for a million bytes" do
    Crystal::Digest::SHA256.hexdigest("a" * 1_000_000).should eq("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
  end

  it "can't call #final more than once" do
    digest = Crystal::Digest::SHA256.new
    digest.final
    expect_raises(Digest::FinalizedError) do
      digest.final
    end
  end

  it "returns the digest_size" do
    Crystal::Digest::SHA256.new.digest_size.should eq(32)
  end
end
