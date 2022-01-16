const std = @import("std");




// Load the word lists at compile time
const guesses_raw = @embedFile("guesses.txt");
pub const TOTAL_WORDS = guesses_raw.len / 6;

const answers_raw = @embedFile("answers.txt");
pub const ANS_WORDS = answers_raw.len / 6;

pub const POSSIBLE_SCORES = std.math.pow(u8, 3, 5);

// Pre-computed table with the results of each guess-answer comparison
// according to the index of the words in our input word lists.
// Storage order is chosen this way since our inner loops loop over the answer 
// words while holding the guess word constant
pub var scores: [TOTAL_WORDS][ANS_WORDS]u8 = undefined;

// For the (small) amount of computation we do that actually requires the letters
pub const Word = [5]u8;

var gpa = std.heap.GeneralPurposeAllocator(.{.thread_safe = true}){};
const alloc = gpa.allocator();

fn printUsage() !void {
    std.debug.print(
        \\Usage: 
        \\wordle first [threads] -- 
        \\     calculate optimal first word (about 40 minutes with threads=1 )
        \\
        \\wordle second [first-guess] -- 
        \\     print out a table of second guess words to use for each possible
        \\     response to the first guess
    , .{});
}

pub fn main() !void {
    if (std.os.argv.len < 3) {
        try printUsage();
        std.os.exit(1);
    } 
    const command = std.mem.span(std.os.argv[1]);
    const arg = std.mem.span(std.os.argv[2]);
    if (std.mem.eql(u8, command, "first")) {
        const threads = try std.fmt.parseInt(u32, arg, 10);
        try firstGuess(threads);
    } else if (std.mem.eql(u8, command, "second")) {
        if (arg.len != 5) {
            std.debug.print("first-guess must have 5 letters\n\n", .{});
            std.os.exit(1);
        }
        if (wordToGuess(arg[0..5].*) == null) {
            std.debug.print("first-guess not in word list\n", .{});
            std.os.exit(1);
        }
        try secondGuess(arg[0..5].*);
    } else {
        try printUsage();
    }
}


// Calculate the score of guess when the correct word is ans.
// Encode the result as a 5-digit base-3 number, where 0=grey, 1=yellow, 2=green
// Code adapted from https://github.com/LaurentLessard/wordlesolver/blob/a5110b8d3d6be5230a1ab41e3849034ac706f0fb/utils.jl#L32
pub fn wordScore(guess: Word, ans: Word) u8 {
    var counts: [26]u8 = std.mem.zeroes([26]u8);
    for (ans) |c| {
        counts[c - 'a'] += 1;
    }

    var s2: u8 = 0;
    for (guess) |c, i| {
        s2 *= 3;
        if (c == ans[i]) {
            s2 += 2;
            counts[c - 'a'] -= 1;
        }
    }
    var s1: u8 = 0;
    for (guess) |c, i| {
        s1 *= 3;
        if (ans[i] != c and contains(ans, c) and counts[c - 'a'] > 0) {
            s1 += 1;
            counts[c - 'a'] -= 1;
        }
    }
    return s1 + s2;
}

// Calculate the number of different responses we can get for a given guess
pub fn numSplits(guess: usize, solution_pool: []u16) u32 {
    var set = std.StaticBitSet(POSSIBLE_SCORES).initEmpty();
    for (solution_pool) |ans| {
        set.set(scores[guess][ans]);
    }
    return @intCast(u32, set.count());
}

// Calculate the least-specific response we can get for a given guess
// Return the number of possible answers after that least-specific response
fn worstSplit(guess: usize, solution_pool: []u16) u32 {
    var count = std.mem.zeroes([POSSIBLE_SCORES]u16);
    for (solution_pool) |ans| {
        count[scores[guess][ans]] += 1;
    }
    var max_size: u32 = 0;
    for (count) |c| max_size = @maximum(max_size, c);
    return max_size;
}

// Helper function for dividing lists of possible answers
pub fn guessComparator(guess: usize, ans1: u16, ans2: u16) bool {
    return scores[guess][ans1] < scores[guess][ans2];
}

// Determine how many words we will guess within 3 turns, given the
// intial guess word
fn evalInitialGuess(guess: usize) u32 {
    var answers: [ANS_WORDS]u16 = undefined;
    for (answers) |*x, i| x.* = @intCast(u16, i);

    std.sort.sort(u16, answers[0..], guess, guessComparator);

    var start: usize = 0;
    var end: usize = 0;

    var sum: u32 = 0;

    while (start < ANS_WORDS) : (start = end) {
        while (end < ANS_WORDS and scores[guess][answers[start]] == scores[guess][answers[end]]) {
            end += 1;
        }

        const solution_pool: []u16 = answers[start..end];
        var guess2: usize = 0;
        var max_splits: u32 = 0;

        while (guess2 < TOTAL_WORDS) : (guess2 += 1) {
            max_splits = @maximum(max_splits, numSplits(guess2, solution_pool));
        }
        sum += max_splits;
    }
    return sum;
}


// Shared global state to coordinate the threads for first-guess search
var workerProgress: u32 = 0; 
var workerMutex = std.Thread.Mutex{};
var workerBest: u32 = 0;
var workerResults: std.ArrayList(usize) = undefined;

fn updateProgress(amount: u32) void {
    workerMutex.lock();
    const barsPre = (workerProgress * 20) /  TOTAL_WORDS;
    workerProgress += amount;
    var barsPost = (workerProgress * 20) /  TOTAL_WORDS;
    while (barsPost > barsPre) : (barsPost -= 1) {
        std.debug.print("-", .{});
    }
    if (workerProgress == TOTAL_WORDS) {
        std.debug.print("|\n", .{});
    }
    workerMutex.unlock();
}

fn scoreWorker(thread_id: u32, total_threads: u32) !void {
    var i = thread_id;
    var bestScore: u32 = 0;

    var bestResults = std.ArrayList(usize).init(alloc);
    defer bestResults.deinit();

    var pendingProgress: u32 = 0;
    while (i < TOTAL_WORDS) : (i += total_threads) {
        const guessScore = evalInitialGuess(i);
        if (guessScore > bestScore) {
            bestScore = guessScore;
            try bestResults.resize(0);
            try bestResults.append(i);
        } else if (guessScore == bestScore) {
            try bestResults.append(i);
        }

        pendingProgress += 1;
        if (pendingProgress % 10 == 0) {
            updateProgress(pendingProgress);
            pendingProgress = 0;
        }
    }

    updateProgress(pendingProgress);

    workerMutex.lock();
    if (workerBest < bestScore) {
        try workerResults.resize(0);
        workerBest = bestScore;
        try workerResults.appendSlice(bestResults.items);
    } else if (workerBest == bestScore) {
        try workerResults.appendSlice(bestResults.items);
    }
    workerMutex.unlock();
}

fn firstGuess(threads: u32) !void {
    calculateScores();
    std.debug.print("Calculating first guess with {d} threads\n", .{threads});
    std.debug.print("|--------------------|\n|", .{});
    
    var handles = try alloc.alloc(std.Thread, threads);
    defer alloc.free(handles);

    workerResults = std.ArrayList(usize).init(alloc);
    defer workerResults.deinit();

    var tid: u8 = 0;
    while (tid < threads) : (tid += 1) {
        handles[tid] = try std.Thread.spawn(.{.stack_size = (1<<20)}, scoreWorker, .{tid, threads});
    }

    tid = 0;
    while (tid < threads) : (tid += 1) {
        handles[tid].join();
    }
    std.debug.print("Found {d} words with probability {d}/{d} of winning in 3 turns\n", .{
        workerResults.items.len, workerBest, ANS_WORDS
    });
    for (workerResults.items) |guess| {
        std.debug.print("{s}\n", .{guessToWord(guess)[0..]});
    }
}


fn secondGuess(guess_text: Word) !void {
    calculateScores();

    const guess = wordToGuess(guess_text).?;

    var answers: [ANS_WORDS]u16 = undefined;
    for (answers) |*x, i| x.* = @intCast(u16, i);

    std.sort.sort(u16, answers[0..], guess, guessComparator);

    var start: usize = 0;
    var end: usize = 0;    
    
    var worst_split: u32 = 0;
    while (start < ANS_WORDS) : (start = end) {
        while (end < ANS_WORDS and scores[guess][answers[start]] == scores[guess][answers[end]]) {
            end += 1;
        }

        const solution_pool: []u16 = answers[start..end];
        var guess2: u32 = 0;
        var max_splits: u32 = 0;
        var best_guess: u32 = 0;
        
        while (guess2 < TOTAL_WORDS) : (guess2 += 1) {
            const splits = numSplits(guess2, solution_pool);
            if (splits > max_splits) {
                max_splits = splits;
                best_guess = guess2;
            }
        }
        worst_split = @maximum(worst_split, worstSplit(guess2, solution_pool));

        if (solution_pool.len <= 2) {
            best_guess = @intCast(u32, wordToGuess(ansToWord(solution_pool[0])).?);
        }
        try printScore(scores[guess][answers[start]]);
        std.debug.print(" {s}\n", .{guessToWord(best_guess)});
    }
    std.debug.print("Worst case remaining words: {d}\n", .{worst_split});
}



// HELPER FUNCTIONS

// Utility functions for converting to/from word indices
pub fn wordToGuess(w: Word) ?usize {
    var i: u32 = 0;
    while (i < TOTAL_WORDS) : (i += 1) {
        if (std.meta.eql(guessToWord(i), w)) return i;
    }
    return null;
}

pub fn guessToWord(idx: usize) Word {
    return guesses_raw[idx * 6 ..][0..5].*;
}

pub fn ansToWord(idx: usize) Word {
    return answers_raw[idx * 6 ..][0..5].*;
}

// Used in score calculation
fn contains(w: Word, c: u8) bool {
    return std.mem.indexOfScalar(u8, w[0..], c) != null;
}

// Precompute the scores array
pub fn calculateScores() void {
    var i: u32 = 0;
    while (i < TOTAL_WORDS) : (i += 1) {
        var j: u32 = 0;
        while (j < ANS_WORDS) : (j += 1) {
            scores[i][j] = wordScore(guessToWord(i), ansToWord(j));
        }
    }
}

// Print a score number using the colored emoji
fn printScore(score: u8) !void {
    var i: u8 = 0;
    while (i < 5) : (i += 1) {
        const c: []const u8 = switch ((score / std.math.pow(u32, 3, 4-i)) % 3) {
            0 => "⬛",
            1 => "🟨",
            2 => "🟩", 
            else => unreachable
        };
        std.debug.print("{s}", .{c});
    }
}