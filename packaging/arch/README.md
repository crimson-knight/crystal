# crystal-alpha on Arch Linux and Omarchy

`crystal-alpha/PKGBUILD` builds the pinned `v1.21.0-incremental-1` tag with
`makepkg`. It installs `crystal-alpha` (alias `acrystal`) under
`/usr/lib/crystal-alpha` and does not ship `/usr/bin/crystal`, so it coexists
with the official `crystal` package.

Why `llvm21-libs` and not `llvm-libs`: Arch's `llvm` is version 23 now, and
this compiler needs LLVM 21.1.x. Arch ships `llvm21` / `llvm21-libs` side by
side with it, and the package depends on those.

Pins: the source tarball and the bootstrap Crystal 1.20.0-1 (x86_64) are both
verified by `sha256sums` and `makepkg` fails closed on a mismatch. The bootstrap
is downloaded into the build directory and never touches an installed `crystal`.
Only x86_64 is built and tested.

## Build and install locally

```sh
cd packaging/arch/crystal-alpha
makepkg -si          # as a normal user, not root
crystal-alpha --version
```

To build in the same pinned container CI uses (needs Docker, x86_64 image):

```sh
packaging/arch/run-in-container.sh   # result lands in dist/
```

## Bump to a new release

```sh
packaging/update-pins.sh v1.21.0-incremental-2   # rewrites pins.env, PKGBUILD, .SRCINFO
git diff
cd packaging/arch/crystal-alpha && makepkg --printsrcinfo > .SRCINFO   # authoritative regeneration
```

CI checks that the committed `.SRCINFO` equals `makepkg --printsrcinfo` output.

## Submit to the AUR (one-time, needs Seth's AUR account)

CI never publishes to the AUR. To do it by hand:

1. Create an account at https://aur.archlinux.org and add your SSH public key
   under My Account.
2. Check the name is free: `https://aur.archlinux.org/packages/crystal-alpha`
   should 404.
3. Clone the empty AUR repo and copy the two files in:

   ```sh
   git clone ssh://aur@aur.archlinux.org/crystal-alpha.git aur-crystal-alpha
   cp packaging/arch/crystal-alpha/PKGBUILD packaging/arch/crystal-alpha/.SRCINFO aur-crystal-alpha/
   cd aur-crystal-alpha
   ```
4. Build once more from that directory to be sure: `makepkg -f` and, if you have
   it, `namcap PKGBUILD *.pkg.tar.zst`.
5. Commit and push. The AUR branch must be `master`:

   ```sh
   git add PKGBUILD .SRCINFO
   git commit -m "Initial import: crystal-alpha 1.21.0.incremental1"
   git push origin master
   ```
6. Omarchy users then install with `yay -S crystal-alpha`.

For later releases, repeat steps 3 to 5 with the updated `PKGBUILD` and `.SRCINFO`
(bump `pkgver`, reset `pkgrel` to 1, keep `sha256sums` in sync).

If you also want a prebuilt binary package (no 20 minute compile), the CI
`arch-x86_64` artifact and the release asset are a `.pkg.tar.zst` that installs
with `sudo pacman -U crystal-alpha-*.pkg.tar.zst` after checking it against
`SHA256SUMS`. A `-bin` AUR package or a custom pacman repository is a separate
decision.
