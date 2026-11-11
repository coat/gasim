//! The F18A is an 18-bit computer designed by Chuck Moore.

pub const Word = i18;

/// position of an opcode within an instruction word
pub const Slot = u2;

/// type used by the P register
pub const ProgramCounter = packed struct(u10) {
    /// holds the address of the next word in the instruction stream
    address: Address,
    /// P9 has no effect on memory decoding; it simply enables the Extended Arithmetic Mode when set.
    extended_arithmetic: bool,

    /// Within RAM or ROM, an address is incremented after each word is fetched,
    /// circularly within whichever storage class it currently points to. Within I/O
    /// space, it is not incremented. Incrementing never affects bits P8 or P9
    pub fn increment(self: *ProgramCounter) void {
        if (!self.address.io) self.address.local +%= 1;
    }

    /// The destination field replaces the low order bits of P. Slot 0 jumps can
    /// reach any address and set P9. Slot 1 and 2 jumps leave P9 unchanged and
    /// force P8 to zero, so they can never land in I/O space.
    pub fn jump(self: *ProgramCounter, slot: Slot, instruction: Word) void {
        const p: u10 = @bitCast(self.*);
        self.* = @bitCast(switch (slot) {
            0 => @as(LongJump, @bitCast(instruction)).destination,
            1 => (p & 0x200) | @as(Jump, @bitCast(instruction)).destination,
            2 => (p & 0x2f8) | @as(ShortJump, @bitCast(instruction)).destination,
            else => return,
        });
    }

    /// R holds all 10 bits of P, so Extended Arithmetic Mode survives call/return.
    pub fn toWord(self: ProgramCounter) Word {
        return @as(u10, @bitCast(self));
    }

    pub fn fromWord(word: Word) ProgramCounter {
        return @bitCast(@as(u10, @truncate(@as(u18, @bitCast(word)))));
    }

    pub const reset: ProgramCounter = .{
        .extended_arithmetic = false,
        .address = .reset,
    };
};

/// Address is a 9-bit value that points to a location in memory or
/// memory-mapped I/O.
pub const Address = packed struct(u9) {
    local: u7,
    rom: bool,
    io: bool,

    pub fn toWord(self: Address) Word {
        const word: u9 = @bitCast(self);
        return word;
    }

    pub fn fromWord(word: Word) Address {
        return @bitCast(@as(u9, @intCast(word & 0x1ff)));
    }

    /// initial state on reset
    pub const reset: Address = .{
        .io = false,
        .rom = true,
        .local = 0x2a,
    };
};

pub const LongJump = packed struct(Word) {
    destination: u10,
    _: u8 = 0,
};

pub const Jump = packed struct(Word) {
    destination: u8,
    _: u10 = 0,
};

pub const ShortJump = packed struct(Word) {
    destination: u3,
    _: u15 = 0,
};

pub const Instruction = packed struct(Word) {
    slot_3: u3,
    slot_2: Opcode,
    slot_1: Opcode,
    slot_0: Opcode,

    /// Instruction words are stored XORed with this value. Jump destination
    /// fields are the exception: they are stored as-is.
    pub const encoding: Word = 0x15555;

    pub fn encode(self: Instruction) Word {
        return @as(Word, @bitCast(self)) ^ encoding;
    }

    pub fn decode(word: Word) Instruction {
        return @bitCast(word ^ encoding);
    }

    /// Encodes an instruction ending with a jump, call, next, if or -if in
    /// `slot` whose destination field replaces the remaining slots.
    pub fn encodeJump(self: Instruction, slot: Slot, destination: u10) Word {
        return (self.encode() & ~destinationMask(slot)) | destination;
    }

    /// Mask of the destination field of a jump in `slot`
    pub fn destinationMask(slot: Slot) Word {
        return switch (slot) {
            0 => 0x3ff,
            1 => 0xff,
            2 => 0x7,
            else => 0,
        };
    }

    pub fn getSlot(self: Instruction, slot: Slot) Opcode {
        return switch (slot) {
            0 => self.slot_0,
            1 => self.slot_1,
            2 => self.slot_2,
            3 => Opcode.fromInt(self.slot_3),
        };
    }
};

/// An F18A computer
pub const Computer = struct {
    /// where this process has them, which a snapshot's nodes are attached
    /// to again
    pub const snapshot_skip = .{ "ports", "pin_device", "bus_device" };

    pub const Transfers = struct {
        read: port.Select = .empty,
        written: port.Select = .empty,
        value_read: Word = 0,
        value_written: Word = 0,

        pub fn any(self: Transfers) bool {
            return self.read.count() > 0 or self.written.count() > 0;
        }
    };

    const State = enum {
        fetch,
        execution,
        /// unext is looping back to slot 0 of the current instruction word
        unext,
        /// `step` left a `unext` loop between two passes, at slot 0, for the
        /// next step to go on with (see `unext_passes`)
        paused,
    };

    /// How many passes of a `unext` loop a step runs before it leaves the
    /// rest to the next step. A loop can go on forever, as `dup >r unext`
    /// does with T not 0, and a step that never ended would stop everything
    /// else: the other nodes, a run's limits and ctrl+c. A delay loop of
    /// fewer passes, such as a bit of a UART at 115200 baud or faster, is
    /// still one step.
    pub const unext_passes = 4096;

    /// address of the io register
    pub const io_address: u9 = 0x15d;
    /// address of the data register of nodes with a parallel bus or SERDES
    pub const data_address: u9 = 0x141;
    /// io register bits reporting whether the node at the other end of each
    /// port is reading (active low) or writing
    const handshake_bits: u18 = 0x1fe00;
    /// io register bit that, when set, has a read of the wakeup pin wait for
    /// it to be low rather than high
    const wake_low_bit: u18 = 1 << 11;
    /// io register bit DB, which, set as it is from reset, has a node with a
    /// parallel bus drive it from its data register, and clear, read it as
    /// inputs (DB001 3.5; bit 12, as the SRAM cluster's io values have it)
    pub const bus_driven_bit: u18 = 1 << 12;

    /// control and status for communication ports and I/O logic.
    io: Word,
    /// serves as a "program counter" and extended arithmetic flag
    p: ProgramCounter,
    /// general purpose read/write address or data register
    a: Word,
    /// write only address register, on reset holds the address of io register
    b: u9,
    /// instruction words containing 1, 2, 3 or 4 opcodes for execution
    i: Word,
    /// where I was fetched from
    word_address: Address,
    /// top 64 words are RAM, bottom half are ROM
    mem: [128]Word,
    // 9 word stack
    return_stack: stack.ReturnStack,
    // 10 word stack
    data_stack: stack.DataStack,
    // involved in some Extended Arithmetic mode instructions
    carry: u1,

    /// right, down, left and up comm ports; unconnected ports are null
    ports: [4]port.Link,
    /// io bits of the GPIO pins this node has, out of 17, 5, 3 and 1
    pins: u18,
    /// levels of the pins when the node is not driving them, and always of
    /// the pins on nets with something else on them (`shared_pins`), as the
    /// nets are. Pins are pulled low after reset.
    pin_inputs: u18,
    /// the data register, for nodes that have one
    data: ?Word,
    /// the port that reads GPIO pin 17 as a wakeup pin, for edge nodes that
    /// have one: Up on the top and bottom edges, Left on the sides. A read
    /// waits until the pin is in the state WD in io selects, unless a device
    /// is attached to the port.
    wake_port: ?port.Direction = null,
    /// a device on the pins, which sees them as the node reads and writes
    /// io, at its time then, as a word can run a long `unext` loop first
    pin_device: ?PinDevice = null,
    /// whether its data register is a parallel bus, and a device on it, if
    /// any
    bus: bool = false,
    bus_device: ?BusDevice = null,
    /// io bits of the pins on a net with something else on it, whose levels
    /// are in `pin_inputs` even while the node drives them, as the net may
    /// be driven otherwise
    shared_pins: u18 = 0,

    state: State = .fetch,
    // keeps track of current slot to help address decoding
    slot: Slot,
    /// waiting in mid-instruction on a comm port. The pending operation is
    /// retried by the next call to `step`.
    suspended: bool,
    /// the comm ports read from and written to by the last call to `step`,
    /// and the last value each way. Reads include instruction words fetched
    /// from a port.
    transfers: Transfers = .{},

    /// picoseconds of execution, which waiting on a port does not add to
    time: u64,

    /// whether the last opcode of the word executed before this one changed
    /// S, T or P9, so that an add in slot 0 is a hazard (see `addUnsettled`)
    unsettled: bool = false,
    /// passes of a `unext` loop left to the step being taken
    unext_left: u16 = unext_passes,
    /// the first hazard since this was last cleared, which `Chip` does
    /// after each step, and how many there were, as a step can have several,
    /// such as one in each pass of a `unext` loop
    hazard: ?Hazard = null,
    hazards: u32 = 0,

    /// The nets of a node's pins (see `pins.Wiring`), told when the node
    /// reads io or a port, to set `pin_inputs` as they are at the node's
    /// time, and when it writes io, which can change how it drives its
    /// pins. A read of a port that catches up with the writer's time does
    /// so after the word, so io later in the same word is at the time
    /// before.
    pub const PinDevice = struct {
        context: *anyopaque,
        read: *const fn (context: *anyopaque, node: *Computer) void,
        written: *const fn (context: *anyopaque, node: *const Computer) void,
    };

    /// A device on a node's 18-bit parallel bus, told when the node writes
    /// its data register, the bus register, or io, which sets whether it
    /// drives the bus, and asked, when the node reads the bus as inputs,
    /// what is on the bus at the node's time: what the device drives, or
    /// the charge the lines keep of what it last drove, or null for that of
    /// what the node drove. The node's Up port, which waits on a phantom
    /// signal, is not the bus here.
    pub const BusDevice = struct {
        context: *anyopaque,
        read: *const fn (context: *anyopaque, node: *const Computer) ?u18,
        written: *const fn (context: *anyopaque, node: *const Computer) void,
    };

    /// Something a node did that a real chip may not do as gasim does, as
    /// DB001 says not to do it
    pub const Hazard = struct {
        kind: Kind,
        /// the word the node was executing, and the slot of the opcode
        address: u9,
        slot: Slot,

        pub const Kind = enum {
            /// `+` or `+*` in slot 0, 1 or 2 straight after an opcode that
            /// changed S, T or P9, with no time for the carry to settle
            /// (DB001 2.3.3)
            unsettled_add,
            /// a write to ROM, which may hang a real node (DB001 2.4.3)
            rom_write,
            /// a read of several ports that two neighbours had written, of
            /// which the node took one word and lost the other (DB001 3.3.1)
            lost_word,

            /// a few words for a list, where `text` is too long
            pub fn short(self: Kind) []const u8 {
                return switch (self) {
                    .unsettled_add => "add with no . before it",
                    .rom_write => "write to ROM",
                    .lost_word => "word lost reading ports",
                };
            }

            pub fn text(self: Kind) []const u8 {
                return switch (self) {
                    .unsettled_add => "added straight after an opcode that changed S, T or P9, which needs a . between (DB001 2.3.3)",
                    .rom_write => "wrote to ROM, which may hang a real node (DB001 2.4.3)",
                    .lost_word => "read several ports that two neighbours had written, and lost a word (DB001 3.3.1)",
                };
            }
        };
    };

    pub const Status = union(enum) {
        running,
        /// executing from a port, waiting for code
        code: u9,
        reading: u9,
        writing: u9,
    };

    /// what the computer is doing, and if it is waiting, the address it
    /// waits on
    pub fn status(self: *const Computer) Status {
        if (!self.suspended) return .running;
        if (self.state == .fetch) return .{ .code = @bitCast(self.p.address) };
        const opcode = Instruction.decode(self.i).getSlot(self.slot);
        const address: u9 = switch (opcode) {
            .@"@p", .@"!p" => @bitCast(self.p.address),
            .@"@b", .@"!b" => self.b,
            else => @intCast(@as(u18, @bitCast(self.a)) & 0x1ff),
        };
        return switch (opcode) {
            .@"@p", .@"@+", .@"@b", .@"@" => .{ .reading = address },
            else => .{ .writing = address },
        };
    }

    /// Whether stepping the suspended computer again would only suspend it
    /// again, changing nothing: each port it waits on would still wait. A
    /// read of the wakeup pin is never counted as waiting, as only reading
    /// it tells.
    pub fn retryWaits(self: *const Computer) bool {
        const reading, const address = switch (self.status()) {
            .running => return false,
            .code, .reading => |address| .{ true, address },
            .writing => |address| .{ false, address },
        };
        // an address that is not a port waits forever
        const ports = port.select(address) orelse return true;
        var it = ports.iterator();
        while (it.next()) |direction| {
            const link = self.ports[@backingInt(direction)];
            const p = link.port orelse {
                if (reading and self.wake_port == direction) return false;
                continue;
            };
            if (!(if (reading) p.readWaits(link.side) else p.writeWaits(link.side))) return false;
        }
        return true;
    }

    /// Executes the rest of the current instruction word, fetching a new one
    /// first if needed. Returns early with `suspended` set when an opcode
    /// must wait on a comm port, or `paused` after `unext_passes` passes of
    /// a `unext` loop, which the next step goes on with.
    pub fn step(self: *Computer) void {
        self.suspended = false;
        self.transfers = .{};
        self.unext_left = unext_passes;
        if (self.state == .paused) self.state = .execution;
        // inlined, as stepSlot calls them too, and this is the run loop's
        if (self.state == .fetch and !@call(.always_inline, fetchWord, .{self})) return;
        while (self.state == .execution) {
            @call(.always_inline, execute, .{ self, Instruction.decode(self.i).getSlot(self.slot) });
            if (self.suspended) return;
        }
    }

    /// whether the last step left a `unext` loop for the next to go on with
    pub fn paused(self: *const Computer) bool {
        return self.state == .paused;
    }

    /// Fetches the next instruction word, if the node is between words, or
    /// otherwise executes the opcode in the current slot. For `unext` that
    /// is one pass of its loop, or of a loop of nothing else, every pass
    /// but the last, which leaves the loop. Running the rest of the word
    /// with `step` afterwards does the same as `step` would have done alone.
    pub fn stepSlot(self: *Computer) void {
        self.suspended = false;
        self.transfers = .{};
        self.unext_left = unext_passes;
        if (self.state == .paused) self.state = .execution;
        if (self.state == .fetch) {
            _ = self.fetchWord();
        } else self.execute(Instruction.decode(self.i).getSlot(self.slot));
    }

    /// Reads the instruction word at P into I, to run from slot 0. Returns
    /// false, suspended, when it must wait on a comm port.
    fn fetchWord(self: *Computer) bool {
        // instructions may be fetched from a port
        self.i = self.read(self.p.address) orelse return false;
        self.word_address = self.p.address;
        self.p.increment();
        self.slot = 0;
        self.state = .execution;
        return true;
    }

    /// The address of the instruction word being executed, or between words,
    /// of the word to be fetched next
    pub fn current(self: *const Computer) Address {
        return if (self.state == .fetch) self.p.address else self.word_address;
    }

    pub fn execute(self: *Computer, opcode: Opcode) void {
        const code = @backingInt(opcode);
        // the address a memory opcode uses, before it moves A or P on. DB002
        // only times @p and !p as memory opcodes, but with P in io space, as
        // in port execution, they read and write the port as @b and !b do
        const io = switch (opcode) {
            .@"@p", .@"!p" => self.p.address.io,
            .@"@b", .@"!b" => self.b & 0x100 != 0,
            .@"@+", .@"@", .@"!+", .@"!" => self.a & 0x100 != 0,
            else => false,
        };
        // DB002's empty next, `begin next`: the next is its word's whole
        // loop, and jumps back to it
        const empty_next = opcode == .next and self.slot == 0 and self.return_stack.t != 0;
        opcodes.opcodes[code](self);
        if (self.suspended) return;

        // typical times of the G144A12 (DB002 §5.3), in picoseconds. Not
        // added in place, as advancing to the next word adds its fetch time
        const time: u64 = time: switch (code) {
            0x00...0x03, 0x05...0x07 => {
                // transfer of program control ends the instruction word
                self.state = .fetch;
                const empty = empty_next and @as(u9, @bitCast(self.p.address)) == @as(u9, @bitCast(self.word_address));
                // these leave S and T, and note themselves whether they
                // changed P9, which an add uses (`unsettled`)
                break :time if (empty) 5000 else 5200;
            },
            0x04 => {
                if (self.state == .unext) {
                    // A unext in slot 0 is its whole loop, a delay, as
                    // `for unext` is. The passes left only count R down,
                    // so they are taken at once, in the time they take.
                    if (self.slot == 0) {
                        self.time += @as(u64, @as(u18, @bitCast(self.return_stack.t))) * 2400;
                        self.return_stack.t = 0;
                    }
                    self.slot = 0;
                    self.unsettled = false;
                    // any other loop is left to the next step after
                    // `unext_passes` passes, as it may never end
                    self.unext_left -= 1;
                    self.state = if (self.unext_left == 0) .paused else .execution;
                } else self.advance(false);
                break :time 2400;
            },
            0x08...0x0f => {
                self.advance(true);
                break :time if (io) 3500 else 5000;
            },
            else => {
                // An add straight after an opcode that changed S, T or P9
                // is a hazard. Slot 3 is safe, as the next word's fetch
                // gives the carry time, and so is ROM, which works as it is
                // on a real chip.
                if ((opcode == .@"+" or opcode == .@"+*") and self.slot != 3 and !self.word_address.rom and self.addUnsettled()) self.note(.unsettled_add);
                self.advance(opcode != .@".");
                break :time 1400;
            },
        };
        self.time += time;
    }

    /// Counts a hazard, and notes it, at the opcode being executed, unless
    /// one is noted. One found fetching a word is at slot 0, as no opcode
    /// of the word has run.
    pub fn note(self: *Computer, kind: Hazard.Kind) void {
        self.hazards +|= 1;
        if (self.hazard == null) self.hazard = .{ .kind = kind, .address = @bitCast(self.current()), .slot = if (self.state == .fetch) 0 else self.slot };
    }

    /// Whether the opcode executed before the one in the current slot
    /// changed S, T or P9. Worked out only for an add, from the slot before
    /// it, or for slot 0, from how the word before ended, so that other
    /// opcodes do not pay for it.
    fn addUnsettled(self: *const Computer) bool {
        if (self.slot == 0) return self.unsettled;
        return switch (Instruction.decode(self.i).getSlot(self.slot - 1)) {
            // the only opcodes a word runs on from that change none of them
            .@".", .unext => false,
            else => true,
        };
    }

    /// Moves on to the next slot, or the next instruction word after slot
    /// 3, noting then whether the opcode, the word's last, `changed` S or T
    fn advance(self: *Computer, changed: bool) void {
        if (self.slot == 3) {
            self.unsettled = changed;
            self.state = .fetch;
            self.time += fetchTime(Instruction.decode(self.i));
        } else {
            self.slot += 1;
        }
    }

    /// Time to fetch the word after `instruction`, when it ends without a
    /// jump. The next word is prefetched while the opcodes run, unless one
    /// in slot 1, 2 or 3 uses memory, or loops in its word (DB002 §5.3).
    fn fetchTime(instruction: Instruction) u64 {
        const slot_3: Opcode = @fromBackingInt(@intCast(@as(u5, instruction.slot_3) << 2));
        if (delaysFetch(slot_3)) return 4300;
        if (delaysFetch(instruction.slot_2)) return 3200;
        if (delaysFetch(instruction.slot_1)) return 2200;
        return 1200;
    }

    fn delaysFetch(opcode: Opcode) bool {
        const code = @backingInt(opcode);
        return code == 0x04 or (code >= 0x08 and code <= 0x0f);
    }

    /// Reads from memory or I/O space. Returns null, suspending the computer,
    /// while waiting on a comm port. Undefined I/O addresses hang forever.
    pub fn read(self: *Computer, address: Address) ?Word {
        if (!address.io) return self.fetch(address);
        // the pins, read in io and on the wakeup pin's port
        if (self.pin_device) |device| device.read(device.context, self);

        const raw: u9 = @bitCast(address);
        if (raw == io_address) return self.readIo();
        if (raw == data_address) if (self.data) |data| {
            // as inputs: what a device has on the bus, or else the charge
            // the lines keep of what the node drove, taken as its register,
            // which it may have written since without driving
            if (self.bus and !self.drivesBus()) if (self.bus_device) |device| if (device.read(device.context, self)) |value| return @bitCast(value);
            return data;
        };
        if (port.select(raw)) |ports| {
            if (self.readPorts(ports)) |word| return word;
        }
        self.suspended = true;
        return null;
    }

    /// Writes to memory or I/O space. Returns false, suspending the computer,
    /// while waiting on a comm port. Undefined I/O addresses hang forever.
    pub fn write(self: *Computer, address: Address, value: Word) bool {
        if (!address.io) {
            self.store(address, value);
            return true;
        }

        const raw: u9 = @bitCast(address);
        if (raw == io_address) {
            self.io = value;
            if (self.pin_device) |device| device.written(device.context, self);
            if (self.bus_device) |device| device.written(device.context, self);
            return true;
        }
        if (raw == data_address and self.data != null) {
            self.data = value;
            if (self.bus_device) |device| device.written(device.context, self);
            return true;
        }
        if (port.select(raw)) |ports| {
            if (self.writePorts(ports, value)) return true;
        }
        self.suspended = true;
        return false;
    }

    /// A multiport read completes with the first port that is written, or
    /// the wakeup pin reaching the state it waits for
    fn readPorts(self: *Computer, ports: port.Select) ?Word {
        var it = ports.iterator();
        while (it.next()) |direction| {
            const link = self.ports[@backingInt(direction)];
            const word = if (link.port) |p|
                p.read(link.side) orelse continue
            else if (self.awake(direction))
                // a value the program must drop
                0
            else
                continue;
            self.transfers.read.insert(direction);
            self.transfers.value_read = word;
            var others = ports.iterator();
            while (others.next()) |other| {
                const other_link = self.ports[@backingInt(other)];
                if (other_link.port) |o| if (o.cancelRead(other_link.side)) self.note(.lost_word);
            }
            return word;
        }
        return null;
    }

    /// whether a read of the port is of the wakeup pin, and the pin is in
    /// the state it waits for
    fn awake(self: *const Computer, direction: port.Direction) bool {
        if (self.wake_port != direction) return false;
        const low = @as(u18, @bitCast(self.io)) & wake_low_bit != 0;
        return self.pinHigh(1 << 17) != low;
    }

    /// whether a read of the wakeup pin would complete
    pub fn pinAwake(self: *const Computer) bool {
        return self.awake(self.wake_port orelse return false);
    }

    /// Whether the node is suspended reading its wakeup pin, alone or with
    /// other ports
    pub fn waitsOnPin(self: *const Computer) bool {
        const direction = self.wake_port orelse return false;
        const address = switch (self.status()) {
            .code, .reading => |address| address,
            .running, .writing => return false,
        };
        const ports = port.select(address) orelse return false;
        return ports.contains(direction) and self.ports[@backingInt(direction)].port == null;
    }

    /// The level of a GPIO pin, given by its io bit: driven by the node, or
    /// following its input when not, or as its net is (`shared_pins`)
    pub fn pinHigh(self: *const Computer, bit: u18) bool {
        if (self.shared_pins & bit != 0) return self.pin_inputs & bit != 0;
        const written: u18 = @bitCast(self.io);
        // a pin's two control bits start at its io bit: 10 drives it low, 11
        // high, and otherwise it follows its input
        return if (written & bit != 0) written & (bit >> 1) != 0 else self.pin_inputs & bit != 0;
    }

    /// A multiport write is delivered to every port that is already being
    /// read, or completes with the first port to read it
    fn writePorts(self: *Computer, ports: port.Select, value: Word) bool {
        var written = false;
        var it = ports.iterator();
        while (it.next()) |direction| {
            const link = self.ports[@backingInt(direction)];
            const p = link.port orelse continue;
            if (p.write(link.side, value)) {
                written = true;
                self.transfers.written.insert(direction);
                self.transfers.value_written = value;
            }
        }
        if (written) {
            it = ports.iterator();
            while (it.next()) |direction| {
                const link = self.ports[@backingInt(direction)];
                if (link.port) |p| p.cancelWrite(link.side);
            }
        }
        return written;
    }

    /// whether a node with a parallel bus drives it, as DB in io says
    pub fn drivesBus(self: *const Computer) bool {
        return @as(u18, @bitCast(self.io)) & bus_driven_bit != 0;
    }

    /// Bits without I/O facilities read as the inverse of what was last
    /// written. Handshake bits report the state of the far end of each port,
    /// and pin bits the level of each GPIO pin.
    fn readIo(self: *const Computer) Word {
        const written: u18 = @bitCast(self.io);
        var value: u18 = ~written & ~handshake_bits & ~self.pins;
        var pins = self.pins;
        while (pins != 0) : (pins &= pins - 1) {
            const bit = pins & -%pins;
            if (self.pinHigh(bit)) value |= bit;
        }
        for (self.ports, 0..) |link, i| {
            // Rr- is bit 16, Rw is bit 15, Dr- is bit 14 and so on
            const shift: u5 = @intCast(16 - 2 * i);
            const reading = if (link.port) |p| p.otherReading(link.side) else false;
            const writing = if (link.port) |p| p.otherWriting(link.side) else false;
            if (!reading) value |= @as(u18, 1) << shift;
            if (writing) value |= @as(u18, 1) << (shift - 1);
        }
        return @bitCast(value);
    }

    /// Reads RAM or ROM
    pub fn fetch(self: *const Computer, address: Address) Word {
        var local = address.local;
        if (local >= 0x40) {
            local -%= 0x40;
        }
        if (address.rom) {
            return self.mem[local + 64];
        }
        return self.mem[local];
    }

    pub fn store(self: *Computer, address: Address, value: Word) void {
        var local = address.local;
        if (local >= 0x40) {
            local -%= 0x40;
        }
        if (!address.rom) {
            self.mem[local] = value;
        } else self.note(.rom_write);
    }

    pub const reset: Computer = .{
        .io = 0x15555,
        .p = .reset,
        .a = 0,
        .b = 0x15d,
        .i = 0,
        .word_address = .reset,

        .return_stack = .empty,
        .data_stack = .empty,

        .carry = 0,

        .mem = @splat(0),
        .ports = @splat(.{}),
        .pins = 0,
        .pin_inputs = 0,
        .data = null,

        .state = .fetch,
        .slot = 0,
        .suspended = false,
        .time = 0,
    };
};

test "ProgramCounter is reset" {
    var p: ProgramCounter = .reset;
    try expectEqual(false, p.extended_arithmetic);
    try expectEqual(Address.reset, p.address);
    p.address.io = true;
    p.address.rom = false;
}

test "I/O address is not incremented" {
    const io_address: Address = .{ .io = true, .rom = false, .local = 0x00 };
    var p: ProgramCounter = .{ .address = io_address, .extended_arithmetic = false };
    p.increment();
    try expectEqual(0x00, p.address.local);
}

test "RAM address is incremented" {
    const ram_address: Address = .{ .io = false, .rom = false, .local = 0x0a };
    var p: ProgramCounter = .{ .address = ram_address, .extended_arithmetic = false };
    p.increment();
    try expectEqual(0x0b, p.address.local);

    // RAM address wraps
    p.address.local = 0x7f;
    p.increment();
    try expectEqual(0, p.address.local);
}

test "ROM address is incremented" {
    const rom_address: Address = .{ .io = false, .rom = true, .local = 0x0a };
    var p: ProgramCounter = .{ .address = rom_address, .extended_arithmetic = false };
    p.increment();
    try expectEqual(0x0b, p.address.local);

    // ROM address wraps
    p.address.local = 0x7f;
    p.increment();
    try expectEqual(0, p.address.local);
}

test "long jump" {
    var p: ProgramCounter = .reset;

    const instruction: Word = @bitCast(LongJump{ .destination = 0b1100000010 });
    p.jump(0, instruction);

    try expectEqual(true, p.extended_arithmetic);
    try expectEqual(true, p.address.io);
    try expectEqual(false, p.address.rom);
    try expectEqual(0b10, p.address.local);
}

test "jump" {
    var p: ProgramCounter = .reset;

    const instruction: Word = @bitCast(Jump{ .destination = 0b0101010 });
    p.jump(1, instruction);

    try expectEqual(false, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(false, p.address.rom);
    try expectEqual(0b0101010, p.address.local);

    // slot 1 jumps replace P7 so they can move between RAM and ROM
    p.jump(1, @bitCast(Jump{ .destination = 0b10101010 }));
    try expectEqual(true, p.address.rom);
    try expectEqual(0b0101010, p.address.local);
}

test "slot 1 and 2 jumps force P8 to zero and preserve P9" {
    const io_address: Address = .{ .io = true, .rom = true, .local = 0x55 };
    var p: ProgramCounter = .{ .address = io_address, .extended_arithmetic = true };
    p.jump(1, @bitCast(Jump{ .destination = 0x12 }));
    try expectEqual(true, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(false, p.address.rom);
    try expectEqual(0x12, p.address.local);

    p = .{ .address = io_address, .extended_arithmetic = true };
    p.jump(2, @bitCast(ShortJump{ .destination = 0b010 }));
    try expectEqual(true, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(true, p.address.rom);
    try expectEqual(0x52, p.address.local);
}

test "ProgramCounter toWord and fromWord keep P9" {
    const p: ProgramCounter = .{ .address = .reset, .extended_arithmetic = true };
    try expectEqual(0x2aa, p.toWord());
    try expectEqual(p, ProgramCounter.fromWord(p.toWord()));
    // bits above P9 are ignored
    try expectEqual(p, ProgramCounter.fromWord(@bitCast(@as(u18, 0x3feaa))));
}

test "jumps from slot 3 have no destination" {
    var p: ProgramCounter = .reset;
    p.jump(3, @bitCast(LongJump{ .destination = 0x155 }));
    try expectEqual(ProgramCounter.reset, p);
}

test "short jump" {
    var p: ProgramCounter = .reset;

    const instruction: Word = @bitCast(ShortJump{ .destination = 0b101 });
    p.jump(2, instruction);

    try expectEqual(false, p.extended_arithmetic);
    try expectEqual(false, p.address.io);
    try expectEqual(true, p.address.rom);
    // only the low 3 bits are replaced: x2A -> x2D
    try expectEqual(0x2d, p.address.local);
}

test "address is set on reset" {
    // reset
    const reset_address: Address = .reset;
    try expectEqual(reset_address.io, false);
    try expectEqual(reset_address.rom, true);
    try expectEqual(reset_address.local, 0x2a);
}

test "toWord" {
    const address: Address = .reset;

    try expectEqual(0xaa, address.toWord());
}

test "fromWord" {
    const word: Word = 0b0000000011100010;
    const address: Address = Address.fromWord(word);

    try expectEqual(false, address.io);
    try expectEqual(true, address.rom);
    try expectEqual(0b1100010, address.local);
}

test LongJump {
    const word: Word = 0b000000001111111101;

    const long_jump: LongJump = .{ .destination = 0b1111111101 };
    try expectEqual(word, @as(Word, @bitCast(long_jump)));
}

test Jump {
    const word: Word = 0b000000000001010101;

    const jump: Jump = .{ .destination = 0b1010101 };
    try expectEqual(word, @as(Word, @bitCast(jump)));
    try expectEqual(word, jump.destination);
    try expectEqual(0, jump._);
}

test ShortJump {
    const word: Word = 0b101;

    const short_jump: ShortJump = .{ .destination = 0b101 };
    try expectEqual(word, @as(Word, @bitCast(short_jump)));
}

test Instruction {
    const instruction: Instruction = .{
        .slot_0 = .@"@p",
        .slot_1 = .@";",
        .slot_2 = .@";",
        .slot_3 = 1,
    };

    try expectEqual(0b010000000000000001, @as(Word, @bitCast(instruction)));
    try expectEqual(instruction.getSlot(0), instruction.slot_0);
    try expectEqual(instruction.getSlot(1), instruction.slot_1);
    try expectEqual(instruction.getSlot(2), instruction.slot_2);
    try expectEqual(instruction.getSlot(3), .unext);
}

test "computer is initialized" {
    const computer: Computer = .reset;

    try expectEqual(0x15555, computer.io);
    try expectEqual(ProgramCounter.reset, computer.p);
    try expectEqual(0, computer.a);
    try expectEqual(0x15d, computer.b);
    try expectEqual(0, computer.i);
    try expectEqual(stack.ReturnStack.empty, computer.return_stack);
    try expectEqual(stack.DataStack.empty, computer.data_stack);
    try expectEqual(0, computer.carry);
    try expectEqual(.fetch, computer.state);
    try expectEqual(@as([128]Word, @splat(0)), computer.mem);
}

test "fetch" {
    var address: Address = .{ .io = false, .rom = false, .local = 0 };
    var computer: Computer = .reset;

    // RAM
    computer.mem[0] = 55;
    // ROM
    computer.mem[0x40] = 123;

    try expectEqual(55, computer.fetch(address));

    // RAM repeats
    address.local += 0x40;
    try expectEqual(55, computer.fetch(address));

    address.rom = true;
    try expectEqual(123, computer.fetch(address));

    var rom_address: Address = @bitCast(@as(u9, 0x080));
    try expectEqual(123, computer.fetch(rom_address));

    // ROM repeats
    rom_address = @bitCast(@as(u9, 0x0c0));
    try expectEqual(123, computer.fetch(rom_address));
}

test "current" {
    var computer: Computer = .reset;
    computer.p.address = Address.fromWord(5);
    // between words, the next word
    try expectEqual(Address.fromWord(5), computer.current());

    // a word that reads a literal, past which P has moved
    computer.mem[5] = Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@"!", .slot_2 = .@".", .slot_3 = 7 });
    computer.a = 0x1d5;
    computer.step();
    try expect(computer.suspended);
    try expectEqual(Address.fromWord(7), computer.p.address);
    try expectEqual(Address.fromWord(5), computer.current());
}

test "store" {
    var address: Address = .{ .io = false, .rom = false, .local = 0 };
    var computer: Computer = .reset;

    // RAM
    computer.store(address, 55);
    try expectEqual(55, computer.mem[0]);

    // RAM repeats
    address.local += 0x40;
    computer.store(address, 123);
    try expectEqual(123, computer.mem[0]);
}

test "computer steps correctly" {
    var computer: Computer = .reset;
    computer.return_stack.push(1);

    const inst_1: Instruction = .{
        .slot_0 = .jump,
        .slot_1 = .@";",
        .slot_2 = .@";",
        .slot_3 = 0,
    };
    const inst_2: Instruction = .{
        .slot_0 = .@".",
        .slot_1 = .@".",
        .slot_2 = .@".",
        .slot_3 = 7,
    };
    const inst_3: Instruction = .{
        .slot_0 = .@"@p",
        .slot_1 = .@">r",
        .slot_2 = .@".",
        .slot_3 = 7,
    };

    const inst_4: Instruction = .{
        .slot_0 = .@"@b",
        .slot_1 = .@"!b",
        .slot_2 = .unext,
        .slot_3 = 7,
    };

    const inst_5: Instruction = .{
        .slot_0 = .@"@p",
        .slot_1 = .@">r",
        .slot_2 = .@".",
        .slot_3 = 7,
    };

    const inst_6: Instruction = .{
        .slot_0 = .next,
        .slot_1 = .@";",
        .slot_2 = .@";",
        .slot_3 = 0x6,
    };

    const nops: Instruction = .{
        .slot_0 = .@".",
        .slot_1 = .@".",
        .slot_2 = .@".",
        .slot_3 = 7,
    };
    computer.mem[64 + 0x2a] = inst_1.encodeJump(0, 0);
    computer.mem[0] = inst_2.encode();
    computer.mem[1] = inst_3.encode();
    computer.mem[2] = 100;
    computer.mem[3] = inst_4.encode();
    computer.mem[4] = inst_5.encode();
    computer.mem[5] = 2;
    computer.mem[6] = nops.encode();
    computer.mem[7] = inst_6.encodeJump(0, 6);
    computer.mem[8] = nops.encode();

    try expectEqual(0x2a, computer.p.address.local);
    try expectEqual(true, computer.p.address.rom);

    computer.step();
    try expectEqual(computer.mem[64 + 0x2a], computer.i);
    try expectEqual(0, computer.p.address.local);
    try expectEqual(false, computer.p.address.rom);

    computer.step();
    try expectEqual(inst_2, Instruction.decode(computer.i));
    try expectEqual(1, computer.p.address.local);

    computer.step();
    try expectEqual(inst_3, Instruction.decode(computer.i));
    try expectEqual(3, computer.p.address.local);

    computer.step();
    try expectEqual(inst_4, Instruction.decode(computer.i));
    try expectEqual(4, computer.p.address.local);

    computer.step();
    try expectEqual(inst_5, Instruction.decode(computer.i));
    try expectEqual(6, computer.p.address.local);

    computer.step();
    try expectEqual(nops, Instruction.decode(computer.i));
    try expectEqual(7, computer.p.address.local);

    computer.step();
    try expectEqual(computer.mem[7], computer.i);
    try expectEqual(6, computer.p.address.local);

    computer.step();
    computer.step();
    computer.step();
    computer.step();
}

test "step fetches through the memory map" {
    var computer: Computer = .reset;
    computer.data_stack.push(7);

    // RAM word 1 via its mirror at x041
    computer.p.address = .{ .io = false, .rom = false, .local = 0x41 };
    computer.mem[1] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    try expectEqual(7, computer.data_stack.s);
    try expectEqual(0x42, computer.p.address.local);

    // ROM word 5 lives at mem[64 + 5], not mem[5]
    computer.p.address = .{ .io = false, .rom = true, .local = 0x05 };
    computer.mem[64 + 5] = Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    try expectEqual(0, computer.data_stack.s);
}

test "unext loops R+1 times then continues with the next slot" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(2);
    computer.data_stack.push(1);
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@"2*", .slot_2 = .unext, .slot_3 = 6 });

    computer.step();
    // dup 2* runs 3 times, then slot 3 dup runs once
    try expectEqual(8, computer.data_stack.t);
    try expectEqual(8, computer.data_stack.s);
    try expectEqual(0, computer.return_stack.t);
    try expectEqual(1, computer.p.address.local);
}

test "a step leaves a long unext loop for the next step to go on with" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.data_stack.push(0);
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@">r", .slot_2 = .@".", .slot_3 = 7 });
    computer.mem[1] = 3 * Computer.unext_passes;
    computer.mem[2] = Instruction.encode(.{ .slot_0 = .@"2*", .slot_1 = .unext, .slot_2 = .inv, .slot_3 = 7 });
    var whole = computer;

    computer.step();
    // three steps of passes, and one for the last pass and the rest
    for (0..3) |k| {
        computer.step();
        try expect(computer.paused());
        try expect(!computer.suspended);
        try expectEqual(0, computer.slot);
        try expectEqual(@as(Word, @intCast((2 - k) * Computer.unext_passes)), computer.return_stack.t);
    }
    computer.step();
    try expect(!computer.paused());
    try expectEqual(-1, computer.data_stack.t);
    try expectEqual(3, computer.p.address.local);

    // which takes the time, and leaves the node, as its slots one by one
    whole.step();
    whole.stepSlot();
    while (whole.state != .fetch) whole.stepSlot();
    try expectEqual(whole.data_stack, computer.data_stack);
    try expectEqual(whole.return_stack, computer.return_stack);
    try expectEqual(whole.p, computer.p);
    try expectEqual(whole.time, computer.time);
}

test "a unext loop of nothing else is taken at once, in the time its passes take" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(0x99);
    // more passes than a step runs of any other loop
    computer.return_stack.push(100_000);
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .unext, .slot_1 = .dup, .slot_2 = .@".", .slot_3 = 7 });
    var slots = computer;

    computer.step();
    try expect(!computer.paused());
    try expectEqual(0x99, computer.return_stack.t);
    // each pass and the last unext, dup, two nops, and the next word's fetch
    try expectEqual(100_001 * 2400 + 3 * 1400 + 1200, computer.time);

    // and a slot step takes them all too
    slots.stepSlot();
    slots.stepSlot();
    try expectEqual(0, slots.return_stack.t);
    try expectEqual(0, slots.slot);
    try expectEqual(100_000 * 2400, slots.time);
}

test "a step ends in a unext loop that never does" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.data_stack.push(5);
    // dup >r unext, which sets R again each pass
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@">r", .slot_2 = .unext, .slot_3 = 7 });
    for (0..3) |_| {
        computer.step();
        try expect(computer.paused());
    }
    try expectEqual(3 * Computer.unext_passes * (1400 + 1400 + 2400), computer.time);
    // and a slot step goes on from where it paused
    computer.stepSlot();
    try expect(!computer.paused());
    try expectEqual(1, computer.slot);
}

test "stepSlot fetches, then runs one opcode, or one pass of unext" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(1);
    computer.data_stack.push(1);
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@"2*", .slot_2 = .unext, .slot_3 = 6 });

    // fetching runs nothing
    computer.stepSlot();
    try expectEqual(.execution, computer.state);
    try expectEqual(0, computer.slot);
    try expectEqual(1, computer.data_stack.t);

    computer.stepSlot();
    try expectEqual(1, computer.slot);
    computer.stepSlot();
    try expectEqual(2, computer.data_stack.t);
    try expectEqual(2, computer.slot);
    // unext goes back to slot 0 while R is nonzero
    computer.stepSlot();
    try expectEqual(0, computer.slot);
    try expectEqual(0, computer.return_stack.t);
    for (0..3) |_| computer.stepSlot();
    try expectEqual(3, computer.slot);
    // and the last slot ends the word
    computer.stepSlot();
    try expectEqual(.fetch, computer.state);
    try expectEqual(4, computer.data_stack.t);
    try expectEqual(1, computer.p.address.local);
}

test "stepping slot by slot ends as a step of the word does" {
    var whole: Computer = .reset;
    whole.p.address = .{ .io = false, .rom = false, .local = 0 };
    whole.return_stack.push(2);
    whole.data_stack.push(1);
    whole.mem[0] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@"2*", .slot_2 = .unext, .slot_3 = 6 });
    var slots = whole;

    whole.step();
    while (true) {
        slots.stepSlot();
        if (slots.state == .fetch) break;
    }
    try expectEqual(whole.data_stack, slots.data_stack);
    try expectEqual(whole.return_stack, slots.return_stack);
    try expectEqual(whole.p, slots.p);
    try expectEqual(whole.time, slots.time);
}

test "a word step after slot steps runs the rest of the word" {
    var whole: Computer = .reset;
    whole.p.address = .{ .io = false, .rom = false, .local = 0 };
    whole.return_stack.push(2);
    whole.data_stack.push(1);
    whole.mem[0] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@"2*", .slot_2 = .unext, .slot_3 = 6 });
    var mixed = whole;

    whole.step();
    // a fetch, dup, and then the rest
    for (0..2) |_| mixed.stepSlot();
    mixed.step();
    try expectEqual(.fetch, mixed.state);
    try expectEqual(whole.data_stack, mixed.data_stack);
    try expectEqual(whole.return_stack, mixed.return_stack);
    try expectEqual(whole.p, mixed.p);
    try expectEqual(whole.time, mixed.time);
}

test "execution time depends on the opcode class" {
    var computer: Computer = .reset;
    computer.slot = 1;

    computer.execute(.@".");
    try expectEqual(1400, computer.time);

    // B is io after reset
    computer.time = 0;
    computer.slot = 1;
    computer.execute(.@"@b");
    try expectEqual(3500, computer.time);

    computer.time = 0;
    computer.slot = 1;
    computer.execute(.@"!");
    try expectEqual(5000, computer.time);

    // and slot 3 adds the time to fetch the next word, here prefetched
    computer.time = 0;
    computer.slot = 2;
    computer.i = Instruction.encode(.{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@"+*", .slot_3 = 4 });
    computer.execute(.@"+*");
    try expectEqual(1400, computer.time);
    computer.time = 0;
    computer.execute(.@"+*");
    try expectEqual(1400 + 1200, computer.time);
    try expectEqual(.fetch, computer.state);
}

test "the time to fetch the next word depends on the last slot to use memory" {
    var computer: Computer = .reset;
    computer.slot = 3;
    computer.i = Instruction.encode(.{ .slot_0 = .@".", .slot_1 = .@"@p", .slot_2 = .@"!b", .slot_3 = 7 });
    computer.execute(.@".");
    try expectEqual(1400 + 3200, computer.time);
}

test "only a next that is its whole word's loop is an empty next" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(1);
    // begin next
    computer.mem[0] = Instruction.encodeJump(.{ .slot_0 = .next, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0);
    computer.step();
    try expectEqual(5000, computer.time);

    // begin dup next, which jumps as any other next does
    computer.time = 0;
    computer.data_stack.push(3);
    computer.mem[0] = Instruction.encodeJump(.{ .slot_0 = .dup, .slot_1 = .next, .slot_2 = .@".", .slot_3 = 7 }, 1, 0);
    computer.return_stack.push(1);
    computer.step();
    try expectEqual(1400 + 5200, computer.time);

    // and a next in a word from a port, which does not move P, ending its
    // loop without jumping
    computer.time = 0;
    computer.p.address = .{ .io = true, .rom = false, .local = 0x55 };
    computer.word_address = computer.p.address;
    computer.i = Instruction.encodeJump(.{ .slot_0 = .next, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0x155);
    computer.state = .execution;
    computer.slot = 0;
    computer.return_stack.push(0);
    computer.execute(.next);
    try expectEqual(5200, computer.time);
}

test "times a multiply as DB002's example does" {
    // .. 17 mul, where
    // mul nn-n a! 17 dup dup / or for / +* unext drop / a ;
    // whose or leaves 0 for for, though the example loops 18 times, so
    // drop, a basic opcode as or is, stands in for it
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.data_stack.push(5);
    computer.data_stack.push(7);
    computer.mem[0] = Instruction.encodeJump(.{ .slot_0 = .@"@p", .slot_1 = .call, .slot_2 = .@".", .slot_3 = 7 }, 1, 8);
    computer.mem[1] = 17;
    computer.mem[8] = Instruction.encode(.{ .slot_0 = .@"a!", .slot_1 = .@"@p", .slot_2 = .dup, .slot_3 = 6 });
    computer.mem[9] = 17;
    computer.mem[10] = Instruction.encode(.{ .slot_0 = .drop, .slot_1 = .@">r", .slot_2 = .@".", .slot_3 = 7 });
    computer.mem[11] = Instruction.encode(.{ .slot_0 = .@"+*", .slot_1 = .unext, .slot_2 = .drop, .slot_3 = 7 });
    computer.mem[12] = Instruction.encode(.{ .slot_0 = .a, .slot_1 = .@";", .slot_2 = .@".", .slot_3 = 7 });

    // its words, and back to the word after the literal. DB002 sums them to
    // 108500 pS, but its unext word's 68400, 2800 and 2200 are 73400, not
    // the 73500 it says
    for (0..5) |_| computer.step();
    try expectEqual(2, computer.p.address.local);
    try expectEqual(108_400, computer.time);
}

test "instruction encoding" {
    const nops: Instruction = .{ .slot_0 = .@".", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 };
    try expectEqual(0x2c9b2, @as(u18, @bitCast(nops.encode())));
    try expectEqual(nops, Instruction.decode(nops.encode()));

    // destination fields are not encoded
    const call: Instruction = .{ .slot_0 = .@"@p", .slot_1 = .call, .slot_2 = .@";", .slot_3 = 0 };
    const word = call.encodeJump(1, 0x12);
    try expectEqual(0x12, word & 0xff);
    try expectEqual(.@"@p", Instruction.decode(word).slot_0);
    try expectEqual(.call, Instruction.decode(word).slot_1);
}

/// connects the right port of `left` to the left port of `right`
fn connect(left: *Computer, right: *Computer, p: *port.Port) void {
    left.ports[@backingInt(port.Direction.right)] = .{ .port = p, .side = .a };
    right.ports[@backingInt(port.Direction.left)] = .{ .port = p, .side = .b };
}

test "computers communicate through a port" {
    var sender: Computer = .reset;
    var receiver: Computer = .reset;
    var p: port.Port = .{};
    connect(&sender, &receiver, &p);

    const ram: Address = .{ .io = false, .rom = false, .local = 0 };
    sender.p.address = ram;
    sender.b = 0x1d5;
    // @p !b @p !b, then two literals
    sender.mem[0] = Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .@"!b", .slot_2 = .@"@p", .slot_3 = 7 });
    sender.mem[1] = 42;
    sender.mem[2] = 43;
    sender.mem[3] = Instruction.encode(.{ .slot_0 = .@"!b", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });

    receiver.p.address = ram;
    receiver.b = 0x175;
    receiver.mem[0] = Instruction.encode(.{ .slot_0 = .@"@b", .slot_1 = .@"@b", .slot_2 = .@"+", .slot_3 = 7 });

    // the sender arrives first and waits for the receiver
    sender.step();
    try expect(sender.suspended);
    try expectEqual(42, sender.data_stack.t);

    try expectEqual(port.Select.empty, sender.transfers.written);

    // the receiver takes the first word and waits for the second
    receiver.step();
    try expect(receiver.suspended);
    try expectEqual(42, receiver.data_stack.t);
    try expectEqual(port.Select.initOne(.left), receiver.transfers.read);
    try expectEqual(42, receiver.transfers.value_read);

    // the sender completes the first write and finishes its instruction word
    sender.step();
    try expect(!sender.suspended);
    try expectEqual(Address.fromWord(3), sender.p.address);
    try expectEqual(port.Select.initOne(.right), sender.transfers.written);
    try expectEqual(42, sender.transfers.value_written);

    // the receiver is not reading again until it resumes, so the sender waits
    sender.step();
    try expect(sender.suspended);

    receiver.step();
    try expect(!receiver.suspended);
    try expectEqual(85, receiver.data_stack.t);

    sender.step();
    try expect(!sender.suspended);
    try expectEqual(port.Port.State.idle, p.state);
}

test "computer executes instructions from a port" {
    var node: Computer = .reset;
    var feeder: Computer = .reset;
    var p: port.Port = .{};
    connect(&feeder, &node, &p);

    // jump to the left port
    node.p.address = Address.fromWord(0x175);

    // the node waits for an instruction word
    node.step();
    try expect(node.suspended);

    // @p and dup, with the literal also read from the port
    try expect(p.write(.a, Instruction.encode(.{ .slot_0 = .@"@p", .slot_1 = .dup, .slot_2 = .@".", .slot_3 = 7 })));
    node.step();
    try expect(node.suspended);
    try expect(p.write(.a, 7));
    node.step();
    try expect(!node.suspended);
    try expectEqual(7, node.data_stack.t);
    try expectEqual(7, node.data_stack.s);
    // P is not incremented in I/O space
    try expectEqual(Address.fromWord(0x175), node.p.address);
}

test "multiport read takes the first written port" {
    var node: Computer = .reset;
    var right: port.Port = .{};
    var up: port.Port = .{};
    node.ports[@backingInt(port.Direction.right)] = .{ .port = &right, .side = .a };
    node.ports[@backingInt(port.Direction.up)] = .{ .port = &up, .side = .a };

    // rdlu
    const rdlu = Address.fromWord(0x1a5);
    try expectEqual(null, node.read(rdlu));
    try expect(node.suspended);
    try expect(right.otherReading(.b));
    try expect(up.otherReading(.b));

    try expect(up.write(.b, 9));
    try expectEqual(9, node.read(rdlu));
    // the pending read on the other port is withdrawn
    try expectEqual(port.Port.State.idle, right.state);
}

test "multiport read discards values written to the other ports" {
    var node: Computer = .reset;
    var right: port.Port = .{};
    var up: port.Port = .{};
    node.ports[@backingInt(port.Direction.right)] = .{ .port = &right, .side = .a };
    node.ports[@backingInt(port.Direction.up)] = .{ .port = &up, .side = .a };

    const rdlu = Address.fromWord(0x1a5);
    try expectEqual(null, node.read(rdlu));

    // both neighbors write before the node resumes
    try expect(right.write(.b, 1));
    try expect(up.write(.b, 2));
    try expectEqual(1, node.read(rdlu));
    try expectEqual(port.Port.State.idle, right.state);
    try expectEqual(port.Port.State.idle, up.state);
    try expectEqual(.lost_word, node.hazard.?.kind);
    try expectEqual(1, node.hazards);

    // the up port is free for a new transfer
    try expect(!node.write(Address.fromWord(0x145), 3));
    try expectEqual(3, up.read(.b));
}

test "io register reports port handshakes" {
    var node: Computer = .reset;
    var right: port.Port = .{};
    node.ports[@backingInt(port.Direction.right)] = .{ .port = &right, .side = .a };

    const io = Address.fromWord(Computer.io_address);
    const rr_: u18 = 1 << 16;
    const rw: u18 = 1 << 15;

    var value: u18 = @bitCast(node.read(io).?);
    try expectEqual(rr_, value & (rr_ | rw));

    _ = right.read(.b);
    value = @bitCast(node.read(io).?);
    try expectEqual(0, value & (rr_ | rw));

    right = .{};
    _ = right.write(.b, 1);
    value = @bitCast(node.read(io).?);
    try expectEqual(rr_ | rw, value & (rr_ | rw));

    // other bits read as the inverse of what was written
    try expect(node.write(io, 0));
    value = @bitCast(node.read(io).?);
    try expectEqual(0x201ff, value & 0x201ff);
}

test "io register reads GPIO pin levels" {
    var node: Computer = .reset;
    node.pins = 1 << 17 | 1 << 1;
    const io = Address.fromWord(Computer.io_address);

    // pins are low after reset, while other bits read inverted
    var value: u18 = @bitCast(node.read(io).?);
    try expectEqual(0, value & (1 << 17 | 1 << 1));
    try expectEqual(1 << 5, value & (1 << 5));

    // following an input
    node.pin_inputs = 1 << 17;
    value = @bitCast(node.read(io).?);
    try expectEqual(1 << 17, value & (1 << 17 | 1 << 1));

    // driven high and low
    try expect(node.write(io, @bitCast(@as(u18, 0b11 << 16 | 0b11))));
    value = @bitCast(node.read(io).?);
    try expectEqual(1 << 17 | 1 << 1, value & (1 << 17 | 1 << 1));
    try expect(node.write(io, @bitCast(@as(u18, 0b10 << 16 | 0b10))));
    value = @bitCast(node.read(io).?);
    try expectEqual(0, value & (1 << 17 | 1 << 1));
}

test "a read of the wakeup pin waits for the state WD selects" {
    var node: Computer = .reset;
    node.pins = 1 << 17;
    node.wake_port = .up;
    const up = Address.fromWord(0x145);
    const rdlu = Address.fromWord(0x1a5);

    // waits for the pin to be high, alone or with other ports
    try expectEqual(null, node.read(up));
    try expect(node.suspended);
    node.pin_inputs = 1 << 17;
    try expectEqual(0, node.read(up));
    try expect(node.transfers.read.contains(.up));
    try expectEqual(0, node.read(rdlu));

    // or low, with WD set
    try expect(node.write(Address.fromWord(Computer.io_address), @bitCast(@as(u18, 0x15555 | 1 << 11))));
    try expectEqual(null, node.read(up));
    node.pin_inputs = 0;
    try expectEqual(0, node.read(up));

    // other ports never wake on the pin
    try expectEqual(null, node.read(Address.fromWord(0x175)));
}

test "data register" {
    var node: Computer = .reset;
    const data = Address.fromWord(Computer.data_address);
    // absent, so it hangs
    try expect(!node.write(data, 1));

    node.data = 0;
    try expect(node.write(data, @bitCast(@as(u18, 0x3fffe))));
    try expectEqual(0x3fffe, @as(u18, @bitCast(node.read(data).?)));
}

test "an add straight after an opcode that changed S or T is a hazard" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    // dup + is one, in slot 1, but not . + after it, nor + in slot 3
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@"+", .slot_2 = .@".", .slot_3 = 5 });
    computer.step();
    try expectEqual(Computer.Hazard{ .kind = .unsettled_add, .address = 0, .slot = 1 }, computer.hazard.?);

    computer.hazard = null;
    computer.mem[1] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@".", .slot_2 = .@"+", .slot_3 = 7 });
    computer.mem[2] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .dup, .slot_2 = .dup, .slot_3 = 5 });
    computer.step();
    computer.step();
    try expectEqual(null, computer.hazard);

    // the word after is too soon, as its fetch gives no time to rely on
    computer.mem[3] = Instruction.encode(.{ .slot_0 = .@"+*", .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    try expectEqual(Computer.Hazard{ .kind = .unsettled_add, .address = 3, .slot = 0 }, computer.hazard.?);
}

test "an add straight after a jump that changed P9 is a hazard, but not in ROM" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.mem[0] = Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0x201);
    computer.mem[1] = Instruction.encode(.{ .slot_0 = .@"+", .slot_1 = .dup, .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    computer.step();
    try expectEqual(.unsettled_add, computer.hazard.?.kind);

    // a jump that leaves P9 as it is changes nothing an add uses
    computer.hazard = null;
    computer.mem[2] = Instruction.encodeJump(.{ .slot_0 = .jump, .slot_1 = .@".", .slot_2 = .@".", .slot_3 = 7 }, 0, 0x201);
    computer.step();
    computer.step();
    try expectEqual(null, computer.hazard);

    // the ROM is as it is on a real chip, where it works
    computer.p = .reset;
    computer.mem[64 + 0x2a] = Instruction.encode(.{ .slot_0 = .dup, .slot_1 = .@"+", .slot_2 = .@".", .slot_3 = 7 });
    computer.step();
    try expectEqual(null, computer.hazard);
}

test "a write to ROM is a hazard, and changes nothing" {
    var computer: Computer = .reset;
    try expect(computer.write(Address.fromWord(0x80), 5));
    try expectEqual(0, computer.mem[64]);
    try expectEqual(.rom_write, computer.hazard.?.kind);
}

test "undefined I/O addresses hang" {
    var node: Computer = .reset;
    try expectEqual(null, node.read(Address.fromWord(0x100)));
    try expect(node.suspended);
    // an unconnected port never completes
    try expect(!node.write(Address.fromWord(0x1d5), 1));
}

test "unext with R zero falls through without looping" {
    var computer: Computer = .reset;
    computer.p.address = .{ .io = false, .rom = false, .local = 0 };
    computer.return_stack.push(0x99);
    computer.return_stack.push(0);
    computer.data_stack.push(5);
    computer.mem[0] = Instruction.encode(.{ .slot_0 = .@".", .slot_1 = .unext, .slot_2 = .dup, .slot_3 = 7 });

    computer.step();
    try expectEqual(5, computer.data_stack.t);
    try expectEqual(5, computer.data_stack.s);
    try expectEqual(0x99, computer.return_stack.t);
    try expectEqual(1, computer.p.address.local);
}

const opcodes = @import("opcodes.zig");
const Opcode = opcodes.Opcode;
const port = @import("port.zig");
const stack = @import("stack.zig");

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "status" {
    var n: Computer = .reset;
    try expectEqual(Computer.Status.running, n.status());

    // fetching from a multiport
    n.p.address = Address.fromWord(0x1a5);
    n.suspended = true;
    try expectEqual(Computer.Status{ .code = 0x1a5 }, n.status());

    // reading through B, and writing through A
    n.state = .execution;
    n.i = Instruction.encode(.{ .slot_0 = .@"@b", .slot_1 = .@"!", .slot_2 = .@".", .slot_3 = 7 });
    n.b = 0x1d5;
    try expectEqual(Computer.Status{ .reading = 0x1d5 }, n.status());
    n.slot = 1;
    n.a = 0x145;
    try expectEqual(Computer.Status{ .writing = 0x145 }, n.status());
}
