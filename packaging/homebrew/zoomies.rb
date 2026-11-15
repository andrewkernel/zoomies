# Homebrew formula for Zoomies. The published copy lives in the tap
# andrewkernel/homebrew-zoomies (Formula/zoomies.rb); this is its source.
# Builds from source on the user's Mac, so no code signing is involved.
class Zoomies < Formula
  desc "Measured, hardware-aware speed tuning for local LLMs (llama.cpp)"
  homepage "https://github.com/andrewkernel/zoomies"
  url "https://github.com/andrewkernel/zoomies/archive/refs/tags/v@VERSION@.tar.gz"
  sha256 "@SHA256@"
  license "MIT"
  head "https://github.com/andrewkernel/zoomies.git", branch: "main"

  depends_on macos: :sonoma
  depends_on "llama.cpp"
  uses_from_macos "swift" => :build

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release", "--product", "zoomies"
    bin.install ".build/release/zoomies"
  end

  def caveats
    <<~EOS
      Find your models:        zoomies models
      Tune one:                zoomies tune <model>
      The Mac app is built by the install script or scripts/build-app.sh:
        https://github.com/andrewkernel/zoomies#install
    EOS
  end

  test do
    assert_match "measured speedups", shell_output("#{bin}/zoomies --help")
    assert_match "Machine", shell_output("#{bin}/zoomies probe")
  end
end
