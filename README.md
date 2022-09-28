# zig-classgen

This is a basic system to generate Zig structs corresponding to C++ classes.
It's pretty messy right now, but it's better than nothing.

## Usage

The generator will target either the Itanium (Linux and macOS) or MSVC (Windows)
C++ ABI depending on the target OS. To use the generator, clone or submodule
it and add the following to your `build.zig`:

```
const classgen = @import("deps/zig-classgen/build.zig");

[...]
try classgen.addPackage(b, exe, "package_name", "class_dir");
[...]
```

This will read class definitions from files in the directory `class_dir` and
expose them all to the `exe` step via the package named `package_name`. The file
`extra.zig` is also read from this directory, and all definitions from it are
included in the exported package. This file may itself import the generated
class definitions using `@import("package_name")`.

Classgen currently does not provide a method to construct classes - it is only
for consuming datastructures from elsewhere.

Pointers to classes may be converted to pointers to any of their base classes
using their `as` method, e.g. `class.as(Base)`. Note that `as` will only convert
to a direct parent - calls must be chained to move up the class hierarchy.
Fields of a class can be accessed via `class.data.field_name`. Virtual methods
are called via `class.methodName(arg1, arg2)`. Inherited or overriden methods
are not directly included on a class - to call these, you must convert the class
to the corresponding base type.

## Class definitions

Class definition files may take any name, although it's recommended to give them
the same name as the class being defined. There is no standard extension for
them (I recommend just not using an extension, or else just `.txt`). Here is a
sample class definition file:

```
# preamble
NAME ClassName
INHERITS Base1
INHERITS Base2

# fields
FIELDS
x: u8
y: ?*ClassName

# virtual methods
VMETHODS
doSomething: fn () void
SKIP 2
getNameConst(GetName): fn () [*:0]const u8
getName(GetName): fn () [*:0]u8
```

Class definitions consist of 3 parts: the preamble, field definitions, and
virtual method definitions. They must always appear in this order, although the
latter two may be omitted if empty. Each section consists of a series of lines
separated by LF characters (`\n`).

The preamble always contains a `NAME` line first. This is followed by zero or
more `INHERITS` directives describing base classes - make sure to match the base
class order from the C++ source, or the structure in memory will differ (note
that virtual inheritance is not supported). The preamble may also contain a line
reading `NON_STANDARD_LAYOUT` if the class is not a [standard layout type]. This
property will be usually be inferred, but there are some conditions which
prevent a class from being standard layout which classgen will not or cannot
identify, such as conflicting access controls on fields. Classgen will correctly
infer non-standard layout when any base class has non-standard layout, when the
class contains virtual methods, and when two or more base classes (or the
inherited class and a base class) both have fields.

The field definitions consist of a series of `name: type` lines. Note that the
full Zig type syntax is not currently supported - instead, the subset of named
types, optionals, pointers, many-pointers (including sentinels), and function
types (which are all assumed to use `callconv(.C)`) are supported, which should
be sufficient for the vast majority of use cases.

The virtual methods section also consists of a series of `name: type` lines, but
here it is expected that `type` is always a function type. The `this` parameter
is automatically prepended to the argument list by classgen, so should not be
included in the class definition file (there is currently no way to specify
`const` methods). Support for variadic functions is WIP. The `name` on these
lines may alternatively take the form `name(other)`, so that the whole line is
of the form `name(other): type`. Here, `other` is called the "dispatch group" of
this method, and is an important part of determining the class layout. When
implementing a class which uses multiple dispatch (i.e. multiple methods with
the same name but different parameter lists), the `name` must be different for
the Zig bindings to be correctly generated, however the binding group _must_ be
specified to be the same in order for the class' vtable to be generated
correctly.

The virtual method section may also include a special directive named `SKIP`.
This instructs classgen to act as if there were some number of methods in the
directive's place - it can be useful when replicating large classes where you
only need some methods. However, it's important to note that due to the rules
around multiple dispatch noted above, you should _always_ include the names, and
crucially dispatch groups, for any function used in multiple dispatches.

If the class has a virtual destructor, it should be replaced with the special
directive `DESTRUCTOR`, since destructors are generated differently to normal
methods on some platforms.

For both fields and virtual methods, a declaration (`name: type` line) may also
begin with a sequeunce like `@LW` to specify that the declaration only exists on
certain platforms. For instance, to specify that a declaration only exists on
Linux, you write `@L name: type`.

[standard layout type]: https://en.cppreference.com/w/cpp/language/data_members#Standard-layout
