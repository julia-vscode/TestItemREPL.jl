# TestItemREPL.jl

> **Prerelease:** TestItemREPL.jl is currently a prerelease package. The API and behavior may change before the first stable release.

TestItemREPL.jl provides an interactive REPL mode for running [test items](https://github.com/julia-testitems/TestItems.jl) directly from the Julia terminal. Press `)` at the `julia>` prompt to enter `test>` mode and run, filter, and inspect tests without leaving the REPL.

## Documentation

Full documentation is available at **https://julia-testitems.org/guide/repl**.

## Quick Start

Install into your global environment:

```julia
using Pkg
Pkg.add(url="https://github.com/julia-testitem/TestItemREPL.jl")
```

Then load it and press `)` to enter the test REPL mode:

```julia
using TestItemREPL
```

```
julia> )
test> run
```

## License

MIT
