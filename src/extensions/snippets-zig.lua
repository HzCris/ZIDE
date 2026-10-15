-- ZIDE Zig snippets: syntax skeletons by plain name.
--
-- They fill the Snippets panel (Ctrl+Alt+B). Click one, or pick it in the
-- command palette, and it lands at the caret with blanks to Tab through;
-- Escape ends the Tab walk and keeps the text. A few also have a Tab
-- trigger: type it and press Tab.
--
-- ZIDE replaces this file with the newest set until you edit it; after
-- that it is yours (delete it to get the newest set again). Edit freely
-- and run reload_extensions. In a body, ${1:text} is a blank with a
-- default, $0 is where the caret ends up, and a leading \t is one
-- indentation level in the document's own style. A name that appears
-- twice (like `list` in the ArrayList skeleton) is plain text, so rename
-- it in every place; mirrored blanks are not supported yet.

local group
local function add(name, trigger, body, notes)
  local command, err = zide.register_snippet({
    language = "zig", group = group, description = name, prefix = trigger, body = body, notes = notes,
  })
  assert(command, err)
end

group = "Start here"
add("Hello world program", "hello",
  "const std = @import(\"std\");\n\npub fn main() void {\n\tstd.debug.print(\"${1:Hello, world!}\\n\", .{});\n}\n$0",
  "The smallest complete program. Save it as main.zig and run it with: zig run main.zig. The first line brings in the standard library as std; main is where the program starts.")
add("Main function", nil,
  "pub fn main() void {\n\t$0\n}",
  "Where a program starts running. void means it gives nothing back. Switch it to !void as soon as you use try inside (see Main that can fail).")
add("Main that can fail", nil,
  "pub fn main() !void {\n\t$0\n}",
  "A main whose code may fail: the ! lets errors come out of it. Use this one when anything inside needs try.")
add("Main with allocator and I/O", nil,
  "pub fn main(init: std.process.Init) !void {\n\tconst gpa = init.gpa;\n\tconst io = init.io;\n\t$0\n}",
  "Zig 0.16 hands main an init with gpa (memory for lists and buffers) and io (files, time, the network). Anything that allocates takes gpa; anything that touches the outside world takes io. Needs the std import at the top (see Import std).")
add("Print", nil,
  "std.debug.print(\"${1:text}\\n\", .{});",
  "Writes text to the terminal (the error stream, so it never mixes with a program's real output). The \\n at the end moves to the next line. Fill the empty .{} to print values: see Print a value.")
add("Print a value", nil,
  "std.debug.print(\"${1:label}: {${2:d}}\\n\", .{${3:value}});",
  "Each {} in the text is filled by one value from the .{} list, in order. {d} prints a number, {s} a string, {any} anything else; a plain {} works for most values.")
add("Import std", nil,
  "const std = @import(\"std\");\n$0",
  "Brings in the standard library under the name std. Put it at the top of every file that uses std.")
add("Import a file", nil,
  "const ${1:name} = @import(\"${2:file}.zig\");",
  "Uses another file of your project: name.something reaches the public (pub) things in file.zig. The path is relative to this file.")

group = "Values"
add("Constant", nil,
  "const ${1:name}: ${2:i32} = ${3:0};",
  "A value that never changes after it is set. The type (i32 = whole number, f64 = decimal, bool = true/false, []const u8 = text) can be left out when Zig can tell it from the value.")
add("Variable", nil,
  "var ${1:name}: ${2:i32} = ${3:0};",
  "A value you can change later with name = ... Zig complains when a var is never changed, so use const for things that stay the same.")
add("String", nil,
  "const ${1:text} = \"${2:hello}\";",
  "Text is a slice of bytes, written []const u8 when you need the type. Use \\n inside the quotes for a line break.")
add("Array", nil,
  "const ${1:numbers} = [_]${2:i32}{ ${3:1, 2, 3} };",
  "A fixed list; [_] lets Zig count the items. Read one with numbers[0] (counting starts at 0) and the length with numbers.len.")
add("Slice of an array", nil,
  "const ${1:part} = ${2:numbers}[${3:0}..${4:2}];",
  "A view of part of an array or another slice: from the first index up to, but not including, the second. Most functions take slices rather than arrays.")
add("Optional", nil,
  "var ${1:maybe}: ?${2:i32} = ${3:null};",
  "A value that may be missing: the ? allows null. Get at the value with If with an optional, or with maybe orelse fallback.")

group = "Functions"
add("Function", "fn",
  "fn ${1:name}($2) ${3:void} {\n\t$0\n}",
  "A named block of code you call with name(). Parameters go in the parentheses as name: type; void means it gives nothing back.")
add("Public function", "pfn",
  "pub fn ${1:name}($2) ${3:void} {\n\t$0\n}",
  "Like Function, but other files can call it through @import.")
add("Function that can fail", "fnerr",
  "fn ${1:name}($2) !${3:void} {\n\t$0\n}",
  "The ! before the return type means the function may return an error instead of a value. Callers deal with it using try, catch or if.")
add("Function that returns a value", nil,
  "fn ${1:name}($2) ${3:i32} {\n\t$0\n\treturn ${4:0};\n}",
  "Gives a value back to the caller with return. The return type comes after the parentheses.")
add("Function with a parameter", nil,
  "fn ${1:name}(${2:number}: ${3:i32}) ${4:void} {\n\t$0\n}",
  "Each parameter is name: type. Inside the function a parameter is a constant; to change the caller's value, take a pointer (*i32) instead.")
add("Method", nil,
  "pub fn ${1:name}(self: *@This()) ${2:void} {\n\t$0\n}",
  "A function inside a struct that works on one value of it: self is that value, and you call it as thing.name(). Use self: @This() (no *) when it only reads.")

group = "If & switch"
add("If", "if",
  "if (${1:condition}) {\n\t$0\n}",
  "Runs the block when the condition is true. Conditions are bool values: comparisons like a == b or a < b, or !done for not.")
add("If / else", "ifelse",
  "if (${1:condition}) {\n\t$2\n} else {\n\t$0\n}",
  "One of the two blocks runs: the first when the condition is true, otherwise the second.")
add("Else if", "elif",
  "if (${1:condition}) {\n\t$2\n} else if (${3:other}) {\n\t$4\n} else {\n\t$0\n}",
  "Checks the conditions in order and runs the first block whose condition is true; the last else runs when none was.")
add("If as a value", nil,
  "const ${1:result} = if (${2:condition}) ${3:1} else ${4:0};",
  "if can produce a value: result gets the first value when the condition is true, otherwise the second. Both must have the same type.")
add("If with an optional", nil,
  "if (${1:maybe}) |${2:found}| {\n\t$0\n}",
  "When the optional holds something, the block runs with it under the name between the bars; null skips the block. Add else { ... } for the null case.")
add("If with an error", nil,
  "if (${1:canFail()}) |${2:found}| {\n\t$0\n} else |err| {\n\tstd.debug.print(\"${3:failed}: {s}\\n\", .{@errorName(err)});\n}",
  "Runs the first block with the result when the call worked, the second with the error when it failed. @errorName turns the error into text.")
add("Switch", "switch",
  "switch (${1:value}) {\n\t${2:else} => {\n\t\t$0\n\t},\n}",
  "Picks one branch by value. Write cases as 1 => ..., or 2, 3 => ... for several values; else catches everything left. Every possible value must be covered.")
add("Switch on an enum", nil,
  "switch (${1:color}) {\n\t.${2:red} => {\n\t\t$3\n\t},\n\t.${4:green} => {\n\t\t$0\n\t},\n}",
  "An enum switch names each member with a leading dot. Zig makes sure no member is forgotten unless you add an else branch.")

group = "Loops"
add("While", "while",
  "while (${1:condition}) {\n\t$0\n}",
  "Repeats the block as long as the condition is true. Change something inside, or use break; to leave.")
add("While with a counter", "whilei",
  "var ${1:i}: usize = 0;\nwhile (i < ${2:count}) : (i += 1) {\n\t$0\n}",
  "Counts from 0 up to, but not including, count. The part after the colon runs after each round; usize is the type Zig uses for counts and indexes.")
add("For each item", "for",
  "for (${1:items}) |${2:item}| {\n\t$0\n}",
  "Runs the block once per item of an array or slice, with the item under the name between the bars. Use |*item| to change the items in place.")
add("For with index", "fori",
  "for (${1:items}, 0..) |${2:item}, ${3:i}| {\n\t$0\n}",
  "Walks the items together with their positions: 0.. counts alongside, so i is 0 for the first item.")
add("For over a range", "forr",
  "for (0..${1:count}) |${2:i}| {\n\t$0\n}",
  "Runs count times, with i going 0, 1, 2, ... The end of a range is not included.")
add("Loop with break and continue", nil,
  "while (${1:condition}) {\n\tif (${2:skip_this}) continue;\n\tif (${3:done}) break;\n\t$0\n}",
  "continue jumps to the next round, break leaves the loop. Both work in for loops too.")

group = "Types"
add("Struct", "struct",
  "const ${1:Name} = struct {\n\t$0\n};",
  "A new type that bundles values. Put fields inside as name: type, and functions that work on it (see Method).")
add("Struct with fields", nil,
  "const ${1:Point} = struct {\n\t${2:x}: ${3:i32},\n\t${4:y}: ${5:i32},\n\t$0\n};",
  "Fields are name: type, one per line, each ending with a comma. Give a field a default with = value after its type.")
add("Make a struct value", nil,
  "const ${1:point} = ${2:Pair}{ .${3:x} = ${4:0}, .${5:y} = ${6:0} };",
  "Fills every field of a struct type by name. Read a field with point.x, and change one with point.x = 5 when point is a var.")
add("Enum", "enum",
  "const ${1:Name} = enum {\n\t${2:member},\n\t$0\n};",
  "A type with a fixed set of named members. Values are written .member once Zig knows the type; compare them with == or switch over them.")
add("Tagged union", nil,
  "const ${1:Shape} = union(enum) {\n\t${2:circle}: ${3:f64},\n\t${4:square}: ${5:f64},\n};",
  "A value that is exactly one of several kinds, each carrying its own data. Make one with Shape{ .circle = 2.5 } and switch on it to see which kind it is.")
add("Error set", "errset",
  "const ${1:Error} = error{\n\t${2:NotFound},\n\t${3:Invalid},\n};",
  "Names the errors a function can return: fn load() Error!Data. Return one with return error.NotFound; (see Return an error).")

group = "Errors"
add("try", nil,
  "try ${1:doSomething()};",
  "Runs the call; if it fails, the error leaves this function right away and goes to the caller. Only works in a function that can fail (one with ! in its return type).")
add("catch with a fallback", nil,
  "const ${1:result} = ${2:canFail()} catch ${3:0};",
  "Uses the value when the call works, the fallback when it fails.")
add("catch with a block", nil,
  "${1:doSomething()} catch |err| {\n\tstd.debug.print(\"${2:failed}: {s}\\n\", .{@errorName(err)});\n\t$0\n};",
  "Handles a failure in place: the block runs with the error under the name err. To stop the function here, end the block with return.")
add("Return an error", nil,
  "return error.${1:NotFound};",
  "Fails the current function with this error. The name is made up on the spot; the function's return type needs a ! for it.")
add("errdefer", nil,
  "errdefer ${1:cleanup()};",
  "Runs only when the function leaves with an error: undo work that is half done, like freeing memory you just allocated. Pairs with defer.")

group = "Memory"
add("Allocate and free", nil,
  "const ${1:buffer} = try gpa.alloc(${2:u8}, ${3:16});\ndefer gpa.free(buffer);\n$0",
  "Asks the allocator for room for 16 values of the type and promises to give it back when the block ends. gpa comes from main's init (see Main with allocator and I/O), or std.testing.allocator in tests.")
add("ArrayList", nil,
  "var ${1:list}: std.ArrayList(${2:i32}) = .empty;\ndefer list.deinit(gpa);\ntry list.append(gpa, ${3:value});\n$0",
  "A list that grows as you append. Zig 0.16 lists carry no allocator, so every call that may grow or free takes gpa. Read the items with list.items.")
add("Arena allocator", nil,
  "var arena = std.heap.ArenaAllocator.init(${1:gpa});\ndefer arena.deinit();\nconst ${2:scratch} = arena.allocator();\n$0",
  "An allocator that frees everything in one go when the arena is destroyed: handy for temporary work where freeing each piece would be a chore.")
add("defer", nil,
  "defer ${1:cleanup()};",
  "Runs this when the current block ends, however it ends. Put the cleanup right after the thing it cleans up: defer list.deinit(gpa); right after making a list.")

group = "Tests"
add("Test block", "test",
  "test \"${1:name}\" {\n\t$0\n}",
  "A check that zig test runs. Inside, use std.testing.expect and friends; a test that returns an error fails. std.testing.allocator is the allocator for tests.")
add("expect", nil,
  "try std.testing.expect(${1:condition});",
  "Fails the test unless the condition is true.")
add("expectEqual", nil,
  "try std.testing.expectEqual(${1:4}, ${2:value});",
  "Fails unless both are equal, printing both when they differ. The expected value goes first.")
add("expectEqualStrings", nil,
  "try std.testing.expectEqualStrings(\"${1:expected}\", ${2:text});",
  "Compares two pieces of text and shows where they first differ.")
add("expectError", nil,
  "try std.testing.expectError(error.${1:NotFound}, ${2:canFail()});",
  "Passes only when the call fails with exactly that error.")
