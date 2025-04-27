# Orion

64-bit register based VM written in [Zig](https://ziglang.org/)

## Usage

Build Orion

```shell
zig build
```

Compile an assembly program to bytecode

```shell
./zig-out/bin/orion build examples/hello.oasm
```

Execute the bytecode in the virtual machine

```shell
./zig-out/bin/orion run app.ob
```
