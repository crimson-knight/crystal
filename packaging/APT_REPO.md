# Hosting an apt repository for crystal-alpha

Status: not set up. CI builds `.deb` files and attaches them to GitHub releases
(`.github/workflows/linux-packages.yml`). Nothing publishes to an apt repository
yet, because that needs a signing key and an account that only Seth controls.
This page compares the options and recommends one.

What any option has to handle:

- Two suites, because the packages differ per Ubuntu release (`noble` = 24.04,
  `resolute` = 26.04) and per architecture (amd64, arm64).
- A repository signing key. Users pin it in a `Signed-By:` keyring, and we
  publish its fingerprint next to the instructions (same pin-and-verify rule as
  every other dependency).
- Ubuntu 24.04 users also need `apt.llvm.org` (`llvm-toolchain-noble-21`), because
  `libllvm21` is not in the 24.04 archive. The package declares the dependency;
  the install page must say so.
- Package size: each `.deb` is about 5 to 10 MB (measured on the first CI run), four
  packages per release, so a few dozen MB per release in the repository.

## Options

| | GitHub Pages + reprepro/aptly | Cloudsmith | Launchpad PPA |
|---|---|---|---|
| Cost | Free | Free tier for open source (storage and bandwidth caps apply) | Free |
| Account needed | GitHub only | Cloudsmith account and API key | Launchpad account, GPG key registered, Ubuntu code of conduct |
| Who signs | Our key (GitHub secret) | Cloudsmith-managed key, or ours | Launchpad |
| Prebuilt `.deb`s | Yes, we upload our CI builds | Yes | No. Launchpad builds from a source package itself |
| Multi-suite (noble, resolute) | Yes, one repo, two suites | Yes | Yes, one upload per series |
| Build needs network | No (we build in CI) | No | No network at all (see below) |
| Control and lock-in | Full, plain static files, easy to move | Hosted service, export possible | Ubuntu-only, Launchpad rules |
| Size limits | Pages: 1 GB site, 100 GB/month soft limits | Plan limits | Generous |
| Setup effort | Medium: a workflow plus a gh-pages branch | Low | High: Debian source packaging |

### GitHub Pages with a signed repository (reprepro or aptly)

A workflow on release takes the four `.deb`s, runs `reprepro includedeb noble ...`
and `reprepro includedeb resolute ...` (or the aptly equivalent), signs `InRelease`
and `Release.gpg` with the key from a GitHub secret, and commits the regenerated
static tree to a `gh-pages` branch. Pages serves it over
HTTPS. `reprepro` is simpler to script for a fixed set of suites; `aptly` has
snapshots, which fits our pinning habits but adds state to keep.

Strengths: free, no third party, files are static and portable, the whole thing
is auditable in git. Weakness: the 1 GB Pages limit, which at this package size
holds dozens of releases but still needs pruning eventually. Keep only the newest few
versions per suite (`reprepro` `Limit:` in `conf/distributions`) and older ones
stay available on the GitHub releases.

### Cloudsmith

Managed apt hosting with a free open-source plan. `cloudsmith push deb
crimson-knight/crystal-alpha/ubuntu/noble file.deb` from CI. Least setup and good
CDN, but it adds a vendor account, an API key secret, and plan caps we do not
control. Reasonable fallback if Pages size becomes a problem.

### Launchpad PPA

PPA builds run in a sandbox with no network, so everything has to be inside the
source package:

- The Crystal bootstrap compiler (1.20.0-1) is normally downloaded. Offline, it
  would have to be vendored into the orig tarball as a binary blob (about 50 MB
  per architecture), which Debian-style policy discourages and which makes the
  source package huge. Using the distro `crystal` package as bootstrap is not an
  option either: Ubuntu does not ship a recent enough one.
- LLVM 21: fine on 26.04 (`llvm-21-dev` is in the archive). Not available on 24.04,
  and a PPA build cannot add `apt.llvm.org`, so noble would need a separate PPA
  that rebuilds LLVM 21 first.
- Ubuntu builders would build amd64, arm64, and others we do not test.

The offline bootstrap and the 24.04 LLVM gap make this the worst fit.

## Recommendation

Start with **GitHub Pages and reprepro**. It keeps hosting free and in our own
hands, matches the pinned-and-verified approach (we publish the key fingerprint,
users pin it with `Signed-By`), and works with the `.deb`s CI already builds. If
the 1 GB cap starts to bite, move the same signed tree to Cloudsmith without
changing the package builds. Skip the PPA.

## What Seth needs to provide

1. A dedicated apt signing key (a separate GPG key, not a personal one). Export
   the private key as a GitHub secret (`APT_SIGNING_KEY`) and publish the public
   key and its fingerprint.
2. Permission to enable GitHub Pages on a `gh-pages` branch of the repository (or
   a separate `crystal-alpha-apt` repository, which keeps the compiler repo's
   history clean and is the safer layout).
3. A decision on the repository URL, for example `https://crimson-knight.github.io/crystal-alpha-apt/`.

Then the user-facing install is:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://crimson-knight.github.io/crystal-alpha-apt/key.asc | sudo tee /etc/apt/keyrings/crystal-alpha.asc >/dev/null
gpg --show-keys /etc/apt/keyrings/crystal-alpha.asc   # compare with the published fingerprint
sudo tee /etc/apt/sources.list.d/crystal-alpha.sources <<SRC
Types: deb
URIs: https://crimson-knight.github.io/crystal-alpha-apt/
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: main
Signed-By: /etc/apt/keyrings/crystal-alpha.asc
SRC
sudo apt update && sudo apt install crystal-alpha
```
