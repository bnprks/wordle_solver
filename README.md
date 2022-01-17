# Wordle Solver
This is the code for a wordle solver for the 538 Riddler puzzle [here](https://fivethirtyeight.com/features/when-the-riddler-met-wordle/)

For the goal of maximizing the probability of winning within 3 turns, this code
finds 2 equivalently good starting words, which result in 1387/2314 words winning within 3 turns (59.94%):
slate, and trace.

## Strategy explanation
The strategy is simplest to explain starting backwards:
- For guess 3, choose the remaining possible answer that comes first alphabetically.
- For guess 2, choose the word that maximzies the number of different color patterns
  we can recieve.
- For guess 1, precompute the best word to guess by brute forcing all possibilities.

The only non-trivial part of this strategy is guess 2. To explain why our strategy makes
sense, notice that the probability of winning in guess 3 is:
`1/[# remaining answers after guess 2]`.

To maximize the probability of winning in guess 3, we want the average number of 
remaining answers after guess 2 to be as low as possible. If we have C different color patterns 
that can result from our second guess, then the average number of remaining answers after guess 2
will be `[# remaining answers after guess 1]/C`. So we reach the conclusion that the
largest value of `C` will lead to the highest probability of winning.

## Using the strategy
Which word is best for the second guess depends on the feedback from the first guess.
The files [slate_second_guess.txt](https://github.com/bnprks/wordle_solver/blob/master/slate_second_guess.txt) and [trace_second_guess.txt](https://github.com/bnprks/wordle_solver/blob/master/trace_second_guess.txt) give the list of appropriate second guesses for each possible piece of feedback.

## Running the code
The code is written in the Zig programming language, which can be downloaded [here](https://ziglang.org/download/).

Compile with:
```
zig build-exe wordle.zig -O ReleaseFast
```

```
Usage:
wordle first [threads] --
     calculate optimal first word (about 40 minutes with threads=1 )

wordle second [first-guess] --
     print out a table of second guess words to use for each possible
     response to the first guess
```

What I ran:
```
./wordle first 4
./wordle second trace 2> trace_second_guess.txt
./wordle second slate 2> slate_second_guess.txt
```
