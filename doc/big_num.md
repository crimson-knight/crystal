# Big numbers on pure Crystal (the default)

`BigInt`, `BigFloat`, `BigRational` and `BigDecimal` run on
`Crystal::BigNum` (`src/crystal/big_num.cr` and `src/crystal/big_num/`),
written in Crystal. A program that requires `big` links no libgmp and
imports no `__gmp` symbol. Existing code keeps its API and its results.

```console
$ crystal build app.cr          # require "big"
$ otool -L app                  # or ldd: no libgmp
```

## Choosing the engine

| Build | Big-number engine |
|---|---|
| `crystal build app.cr` | `Crystal::BigNum` (pure Crystal) |
| `crystal build -Duse_gmp app.cr` | GMP (`src/big/gmp/`, links `libgmp`) |

`-Duse_gmp` is kept for one release, so a program can compare the two
engines on its own numbers. Such a program needs the GMP library where it
is built and where it runs. `to_unsafe` and the constructors that take a raw
`LibGMP::MPZ`, `MPF` or `MPQ` exist only in the `-Duse_gmp` build.

Evidence behind the default: `spec/std/big` and `spec/std/crystal/big_num`
pass in both builds; differentials against GMP found 0 differences in
10,000,000 `BigInt` operations (macOS arm64, Linux arm64, Linux x86_64),
10,000,000 `BigFloat` operations against `mpf` and 3 x 1,000,000
`BigRational` operations against `mpq`. Every `BigInt` operation up to 256
bits is at least as fast as GMP on Apple M4 and Linux arm64.

## Differences

The default engine raises where GMP stops the process:

| Call | Default engine | `-Duse_gmp` |
|---|---|---|
| `unsafe_*` division by zero, `BigInt#remove(0)` | `DivisionByZeroError` | process crash |
| `Math.isqrt` of a negative `BigInt` | `ArgumentError` | SIGFPE |
| `Math.sqrt` of a negative `BigFloat` | `ArgumentError` | SIGFPE |
| NaN or infinity into `BigFloat` | `ArgumentError` | SIGFPE |
| `BigRational` shifted by a negative amount | shifts the other way | SIGFPE |

Both engines keep these GMP readings, for parity:

- `BigFloat` precision is a minimum in bits, held in whole 64-bit limbs
  plus one (`ceil(max(n, 53) / 64) + 1`), and results are truncated.
- `BigFloat` and `BigRational` comparisons return GMP's raw signed values.
- `BigInt#%(Int)` with a negative primitive returns `-(a mod |p|)`
  (`BigInt.new(-5) % -3 == -1`).
- Base-62 `BigInt#to_s` swaps letter case, and `BigInt.new(s, 62)` does not.
