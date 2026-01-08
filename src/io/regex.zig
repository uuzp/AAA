const std = @import("std");

/// 一个轻量级正则实现（Thompson NFA）。
///
/// 支持：
/// - 字面量、转义：\\n \\r \\t \\ \\x（把 x 视为字面量）
/// - `.` 任意字符
/// - 字符类：`[abc]`、范围 `[a-z]`、取反 `[^...]`
/// - 分组：`(...)`
/// - 或：`a|b`
/// - 量词：`*` `+` `?` 以及非贪婪 `*?` `+?` `??`
/// - 锚点：`^`、`$`
///
/// 不支持：反向引用、环视等高级特性。
pub const Error = error{ InvalidRegex, TooComplex };

const ParseError = Error || error{OutOfMemory};

const InstTag = enum {
    Char,
    Any,
    Class,
    Split,
    Jmp,
    AssertStart,
    AssertEnd,
    Match,
};

const Inst = struct {
    tag: InstTag,
    c: u8 = 0,
    class_id: usize = 0,
    out: usize = 0,
    out1: usize = 0,
};

const Range = struct { lo: u8, hi: u8 };
const Class = struct {
    negated: bool,
    ranges: []Range,

    /// 释放字符类的范围数组。
    fn deinit(self: *Class, alloc: std.mem.Allocator) void {
        alloc.free(self.ranges);
    }

    /// 判断字符是否命中该字符类（考虑取反）。
    fn contains(self: Class, ch: u8) bool {
        var hit = false;
        for (self.ranges) |r| {
            if (ch >= r.lo and ch <= r.hi) {
                hit = true;
                break;
            }
        }
        return if (self.negated) !hit else hit;
    }
};

const PatchField = enum { out, out1 };
const Patch = struct { pc: usize, field: PatchField };

const Frag = struct {
    start: usize,
    out: std.ArrayList(Patch),
};

pub const Regex = struct {
    insts: []Inst,
    classes: []Class,
    start_pc: usize,

    /// 编译正则模式，返回可执行的 Regex。
    pub fn init(alloc: std.mem.Allocator, pattern: []const u8) !Regex {
        return compile(alloc, pattern);
    }

    /// 释放 Regex 内部的指令与字符类。
    pub fn deinit(self: *Regex, alloc: std.mem.Allocator) void {
        for (self.classes) |*c| c.deinit(alloc);
        alloc.free(self.classes);
        alloc.free(self.insts);
    }

    /// 从 input 的 start_pos 开始查找第一个匹配区间。
    ///
    /// 返回：{ start, end }，其中 end 为匹配结束位置（不含）。
    pub fn findFirst(self: *const Regex, input: []const u8, start_pos: usize) ?struct { start: usize, end: usize } {
        if (start_pos > input.len) return null;

        var s: usize = start_pos;
        while (s <= input.len) : (s += 1) {
            if (self.matchFrom(input, s)) |end_pos| {
                return .{ .start = s, .end = end_pos };
            }
            if (s == input.len) break;
        }
        return null;
    }

    /// 将 input 中所有匹配片段替换为 replacement，返回新字符串。
    ///
    /// 注意：内部对“空匹配”做了前进保护，避免死循环。
    pub fn replaceAll(self: *const Regex, alloc: std.mem.Allocator, input: []const u8, replacement: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(alloc);

        var i: usize = 0;
        while (i <= input.len) {
            const m = self.findFirst(input, i) orelse {
                try out.appendSlice(alloc, input[i..]);
                break;
            };

            try out.appendSlice(alloc, input[i..m.start]);
            try out.appendSlice(alloc, replacement);

            // 防止空匹配死循环
            if (m.end == m.start) {
                if (m.end < input.len) {
                    try out.append(alloc, input[m.end]);
                    i = m.end + 1;
                } else {
                    break;
                }
            } else {
                i = m.end;
            }
        }

        return out.toOwnedSlice(alloc);
    }

    /// 从 start_pos 开始尝试匹配，成功返回匹配结束位置，否则返回 null。
    fn matchFrom(self: *const Regex, input: []const u8, start_pos: usize) ?usize {
        var cur = std.ArrayList(usize).empty;
        var next = std.ArrayList(usize).empty;
        defer cur.deinit(std.heap.page_allocator);
        defer next.deinit(std.heap.page_allocator);

        // visited 用于 epsilon-closure 去重
        var visited = std.AutoHashMap(usize, void).init(std.heap.page_allocator);
        defer visited.deinit();

        cur.clearRetainingCapacity();
        visited.clearRetainingCapacity();
        addState(self, &cur, &visited, self.start_pc, input, start_pos, start_pos);

        if (containsMatch(self, cur.items)) return start_pos;

        var pos: usize = start_pos;
        while (pos < input.len) : (pos += 1) {
            next.clearRetainingCapacity();
            visited.clearRetainingCapacity();

            const ch = input[pos];
            for (cur.items) |pc| {
                const inst = self.insts[pc];
                switch (inst.tag) {
                    .Char => if (ch == inst.c) addState(self, &next, &visited, inst.out, input, start_pos, pos + 1),
                    .Any => addState(self, &next, &visited, inst.out, input, start_pos, pos + 1),
                    .Class => if (self.classes[inst.class_id].contains(ch)) addState(self, &next, &visited, inst.out, input, start_pos, pos + 1),
                    else => {},
                }
            }

            if (containsMatch(self, next.items)) return pos + 1;

            cur.clearRetainingCapacity();
            cur.appendSlice(std.heap.page_allocator, next.items) catch return null;
        }

        // 处理结尾 $ / epsilon 匹配
        visited.clearRetainingCapacity();
        next.clearRetainingCapacity();
        for (cur.items) |pc| {
            addState(self, &next, &visited, pc, input, start_pos, input.len);
        }
        if (containsMatch(self, next.items)) return input.len;

        return null;
    }
};

/// 当前状态集合中是否包含 Match 指令（表示已匹配成功）。
fn containsMatch(self: *const Regex, pcs: []const usize) bool {
    for (pcs) |pc| {
        if (self.insts[pc].tag == .Match) return true;
    }
    return false;
}

/// 将一个 pc 加入状态集合，并展开 epsilon-closure（Split/Jmp/Assert）。
fn addState(
    self: *const Regex,
    list: *std.ArrayList(usize),
    visited: *std.AutoHashMap(usize, void),
    pc: usize,
    input: []const u8,
    start_pos: usize,
    pos: usize,
) void {
    // epsilon closure
    if (visited.contains(pc)) return;
    visited.put(pc, {}) catch return;

    const inst = self.insts[pc];
    switch (inst.tag) {
        .Split => {
            addState(self, list, visited, inst.out, input, start_pos, pos);
            addState(self, list, visited, inst.out1, input, start_pos, pos);
        },
        .Jmp => addState(self, list, visited, inst.out, input, start_pos, pos),
        .AssertStart => if (pos == 0) addState(self, list, visited, inst.out, input, start_pos, pos),
        .AssertEnd => if (pos == input.len) addState(self, list, visited, inst.out, input, start_pos, pos),
        else => {
            list.append(std.heap.page_allocator, pc) catch {};
        },
    }
}

// ---------------- Parser / AST ----------------

const NodeTag = enum {
    Empty,
    Char,
    Any,
    Class,
    Concat,
    Alt,
    Repeat,
    AssertStart,
    AssertEnd,
};

const RepeatKind = enum { star, plus, qmark };

const Node = union(NodeTag) {
    Empty: void,
    Char: u8,
    Any: void,
    Class: usize, // class id in Parser table
    Concat: []usize,
    Alt: struct { a: usize, b: usize },
    Repeat: struct { sub: usize, kind: RepeatKind, greedy: bool },
    AssertStart: void,
    AssertEnd: void,
};

const Parser = struct {
    alloc: std.mem.Allocator,
    s: []const u8,
    i: usize,

    nodes: std.ArrayList(Node),
    classes: std.ArrayList(Class),

    /// 创建解析器（pattern 生命周期由调用方保证）。
    fn init(alloc: std.mem.Allocator, s: []const u8) Parser {
        return .{
            .alloc = alloc,
            .s = s,
            .i = 0,
            .nodes = std.ArrayList(Node).empty,
            .classes = std.ArrayList(Class).empty,
        };
    }

    /// 释放 Parser 持有的 AST 节点数组。
    fn deinit(self: *Parser) void {
        for (self.classes.items) |*c| c.deinit(self.alloc);
        self.classes.deinit(self.alloc);

        for (self.nodes.items) |n| {
            switch (n) {
                .Concat => |ids| self.alloc.free(ids),
                else => {},
            }
        }
        self.nodes.deinit(self.alloc);
    }

    /// 是否到达输入末尾。
    fn atEnd(self: *Parser) bool {
        return self.i >= self.s.len;
    }

    /// 查看下一个字符（不消费）。
    fn peek(self: *Parser) ?u8 {
        if (self.i >= self.s.len) return null;
        return self.s[self.i];
    }

    /// 消费一个字符并返回（若已结束则返回 null）。
    fn eat(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.i += 1;
        return c;
    }

    /// 追加一个 AST 节点，返回节点 id。
    fn node(self: *Parser, n: Node) ParseError!usize {
        try self.nodes.append(self.alloc, n);
        return self.nodes.items.len - 1;
    }

    /// 解析表达式（处理 `|`）。
    fn parseExpr(self: *Parser) ParseError!usize {
        var left = try self.parseConcat();
        while (self.peek() == '|') {
            _ = self.eat();
            const right = try self.parseConcat();
            left = try self.node(.{ .Alt = .{ .a = left, .b = right } });
        }
        return left;
    }

    /// 解析连接（concatenation）。
    fn parseConcat(self: *Parser) ParseError!usize {
        var parts = std.ArrayList(usize).empty;
        defer parts.deinit(self.alloc);

        while (true) {
            const c = self.peek();
            if (c == null) break;
            if (c.? == ')' or c.? == '|') break;

            const r = try self.parseRepeat();
            try parts.append(self.alloc, r);
        }

        if (parts.items.len == 0) return self.node(.{ .Empty = {} });
        if (parts.items.len == 1) return parts.items[0];

        const owned = try parts.toOwnedSlice(self.alloc);
        return self.node(.{ .Concat = owned });
    }

    /// 解析量词（* + ? 及非贪婪）。
    fn parseRepeat(self: *Parser) ParseError!usize {
        var atom = try self.parseAtom();

        while (true) {
            const c = self.peek() orelse break;
            var kind: ?RepeatKind = null;
            if (c == '*') kind = .star;
            if (c == '+') kind = .plus;
            if (c == '?') kind = .qmark;
            if (kind == null) break;

            _ = self.eat();
            var greedy = true;
            if (self.peek() == '?') {
                _ = self.eat();
                greedy = false;
            }

            atom = try self.node(.{ .Repeat = .{ .sub = atom, .kind = kind.?, .greedy = greedy } });
        }

        return atom;
    }

    /// 解析原子：字面量、分组、点号、字符类、锚点等。
    fn parseAtom(self: *Parser) ParseError!usize {
        const c0 = self.eat() orelse return Error.InvalidRegex;
        switch (c0) {
            '(' => {
                const inside = try self.parseExpr();
                if (self.eat() != ')') return Error.InvalidRegex;
                return inside;
            },
            '.' => return self.node(.{ .Any = {} }),
            '^' => return self.node(.{ .AssertStart = {} }),
            '$' => return self.node(.{ .AssertEnd = {} }),
            '[' => return self.parseClass(),
            '\\' => {
                const c = self.eat() orelse return Error.InvalidRegex;
                return self.node(.{ .Char = parseEscape(c) });
            },
            else => return self.node(.{ .Char = c0 }),
        }
    }

    /// 解析字符类：`[abc]`、范围 `[a-z]`、取反 `[^...]`。
    fn parseClass(self: *Parser) ParseError!usize {
        var negated = false;
        if (self.peek() == '^') {
            _ = self.eat();
            negated = true;
        }

        var ranges = std.ArrayList(Range).empty;
        errdefer ranges.deinit(self.alloc);

        var first = true;
        var prev: ?u8 = null;

        while (true) {
            const c = self.eat() orelse return Error.InvalidRegex;
            if (c == ']' and !first) break;
            first = false;

            var ch: u8 = c;
            if (c == '\\') {
                const e = self.eat() orelse return Error.InvalidRegex;
                ch = parseEscape(e);
            }

            if (self.peek() == '-' and prev == null) {
                // 范围：a-z
                _ = self.eat();
                const c2raw = self.eat() orelse return Error.InvalidRegex;
                var c2: u8 = c2raw;
                if (c2raw == '\\') {
                    const e2 = self.eat() orelse return Error.InvalidRegex;
                    c2 = parseEscape(e2);
                }
                const lo: u8 = @min(ch, c2);
                const hi: u8 = @max(ch, c2);
                try ranges.append(self.alloc, .{ .lo = lo, .hi = hi });
                continue;
            }

            try ranges.append(self.alloc, .{ .lo = ch, .hi = ch });
            prev = ch;
        }

        const owned = try ranges.toOwnedSlice(self.alloc);
        const cls = Class{ .negated = negated, .ranges = owned };
        try self.classes.append(self.alloc, cls);
        const cls_id = self.classes.items.len - 1;

        return self.node(.{ .Class = cls_id });
    }
};

/// 解析简单转义序列（\n \r \t \\ 等）。
fn parseEscape(c: u8) u8 {
    return switch (c) {
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        else => c,
    };
}

// ---------------- Compiler (AST -> NFA) ----------------

const Compiler = struct {
    alloc: std.mem.Allocator,
    insts: std.ArrayList(Inst),
    classes: std.ArrayList(Class),

    /// 创建编译器（持有 inst/class/patch 等临时结构）。
    fn init(alloc: std.mem.Allocator) Compiler {
        return .{
            .alloc = alloc,
            .insts = std.ArrayList(Inst).empty,
            .classes = std.ArrayList(Class).empty,
        };
    }

    /// 释放编译器持有的临时结构。
    fn deinit(self: *Compiler) void {
        for (self.classes.items) |*c| c.deinit(self.alloc);
        self.classes.deinit(self.alloc);
        self.insts.deinit(self.alloc);
    }

    /// 追加一条指令，返回其 pc。
    fn emit(self: *Compiler, inst: Inst) usize {
        self.insts.append(self.alloc, inst) catch {};
        return self.insts.items.len - 1;
    }

    /// 创建一个 patch 列表（只有一个待回填字段）。
    fn list1(self: *Compiler, pc: usize, field: PatchField) std.ArrayList(Patch) {
        var l = std.ArrayList(Patch).empty;
        l.append(self.alloc, .{ .pc = pc, .field = field }) catch {};
        return l;
    }

    /// 将 patch 列表 b 追加到 a。
    fn appendList(self: *Compiler, a: *std.ArrayList(Patch), b: *std.ArrayList(Patch)) void {
        a.appendSlice(self.alloc, b.items) catch {};
    }

    /// 回填 patch 列表中的 out/out1 到 target。
    fn patch(self: *Compiler, list: *std.ArrayList(Patch), target: usize) void {
        for (list.items) |p| {
            switch (p.field) {
                .out => self.insts.items[p.pc].out = target,
                .out1 => self.insts.items[p.pc].out1 = target,
            }
        }
        list.clearRetainingCapacity();
    }

    /// 复制一个字符类（避免共享底层 ranges）。
    fn cloneClass(self: *Compiler, from: Class) !usize {
        const ranges = try self.alloc.alloc(Range, from.ranges.len);
        @memcpy(ranges, from.ranges);
        try self.classes.append(self.alloc, .{ .negated = from.negated, .ranges = ranges });
        return self.classes.items.len - 1;
    }

    /// 编译根节点，返回最终片段（start + out patch 列表）。
    fn compile(self: *Compiler, root: usize) !Frag {
        // root 是 Parser 的节点索引；这里的 compile 由外部保证传入的是 Parser 的 node id。
        // 为了让 Regex.init 简单，这里重新解析时把 Parser 的 nodes/classes 复制进来：
        // 但是我们目前在 Regex.init 里是直接用 Parser 得到的 AST id，这里拿不到 Parser。
        // 解决：Regex.init 在调用 compile 前，会把 Parser 的 nodes/classes 复制进 Compiler。
        _ = self;
        _ = root;
        return Error.InvalidRegex;
    }

    /// 从 Parser 的 AST 编译出 NFA 片段。
    fn compileFrom(self: *Compiler, p: *Parser, root: usize) !Frag {
        // 复制 class 表
        for (p.classes.items) |cls| {
            _ = try self.cloneClass(cls);
        }
        return self.compileNode(p, root);
    }

    /// 编译单个 AST 节点。
    fn compileNode(self: *Compiler, p: *Parser, id: usize) !Frag {
        const n = p.nodes.items[id];
        switch (n) {
            .Empty => {
                const j = self.emit(.{ .tag = .Jmp, .out = 0 });
                return .{ .start = j, .out = self.list1(j, .out) };
            },
            .Char => |ch| {
                const pc = self.emit(.{ .tag = .Char, .c = ch, .out = 0 });
                return .{ .start = pc, .out = self.list1(pc, .out) };
            },
            .Any => {
                const pc = self.emit(.{ .tag = .Any, .out = 0 });
                return .{ .start = pc, .out = self.list1(pc, .out) };
            },
            .Class => |cls_id| {
                const pc = self.emit(.{ .tag = .Class, .class_id = cls_id, .out = 0 });
                return .{ .start = pc, .out = self.list1(pc, .out) };
            },
            .AssertStart => {
                const pc = self.emit(.{ .tag = .AssertStart, .out = 0 });
                return .{ .start = pc, .out = self.list1(pc, .out) };
            },
            .AssertEnd => {
                const pc = self.emit(.{ .tag = .AssertEnd, .out = 0 });
                return .{ .start = pc, .out = self.list1(pc, .out) };
            },
            .Concat => |ids| {
                const first = try self.compileNode(p, ids[0]);
                var out_list = first.out;
                for (ids[1..]) |sub_id| {
                    const next = try self.compileNode(p, sub_id);
                    self.patch(&out_list, next.start);
                    out_list.deinit(self.alloc);
                    out_list = next.out;
                }
                return .{ .start = first.start, .out = out_list };
            },
            .Alt => |ab| {
                var a = try self.compileNode(p, ab.a);
                var b = try self.compileNode(p, ab.b);

                const split = self.emit(.{ .tag = .Split, .out = a.start, .out1 = b.start });

                var out = std.ArrayList(Patch).empty;
                try out.appendSlice(self.alloc, a.out.items);
                try out.appendSlice(self.alloc, b.out.items);
                a.out.deinit(self.alloc);
                b.out.deinit(self.alloc);

                return .{ .start = split, .out = out };
            },
            .Repeat => |r| {
                var sub = try self.compileNode(p, r.sub);

                switch (r.kind) {
                    .star => {
                        const split = if (r.greedy)
                            self.emit(.{ .tag = .Split, .out = sub.start, .out1 = 0 })
                        else
                            self.emit(.{ .tag = .Split, .out = 0, .out1 = sub.start });

                        self.patch(&sub.out, split);
                        sub.out.deinit(self.alloc);

                        const out = self.list1(split, if (r.greedy) .out1 else .out);
                        return .{ .start = split, .out = out };
                    },
                    .plus => {
                        const split = if (r.greedy)
                            self.emit(.{ .tag = .Split, .out = sub.start, .out1 = 0 })
                        else
                            self.emit(.{ .tag = .Split, .out = 0, .out1 = sub.start });

                        self.patch(&sub.out, split);
                        sub.out.deinit(self.alloc);

                        const out = self.list1(split, if (r.greedy) .out1 else .out);
                        return .{ .start = sub.start, .out = out };
                    },
                    .qmark => {
                        const split = if (r.greedy)
                            self.emit(.{ .tag = .Split, .out = sub.start, .out1 = 0 })
                        else
                            self.emit(.{ .tag = .Split, .out = 0, .out1 = sub.start });

                        var out = std.ArrayList(Patch).empty;
                        try out.appendSlice(self.alloc, sub.out.items);
                        try out.append(self.alloc, .{ .pc = split, .field = if (r.greedy) .out1 else .out });
                        sub.out.deinit(self.alloc);

                        return .{ .start = split, .out = out };
                    },
                }
            },
        }
    }
};

/// 编译正则表达式（便捷入口）。
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) !Regex {
    var p = Parser.init(alloc, pattern);
    defer p.deinit();

    const root = try p.parseExpr();
    if (!p.atEnd()) return Error.InvalidRegex;

    var c = Compiler.init(alloc);
    errdefer c.deinit();

    var frag = try c.compileFrom(&p, root);
    defer frag.out.deinit(alloc);

    const m = c.emit(.{ .tag = .Match });
    c.patch(&frag.out, m);

    return .{
        .insts = try c.insts.toOwnedSlice(alloc),
        .classes = try c.classes.toOwnedSlice(alloc),
        .start_pc = frag.start,
    };
}
