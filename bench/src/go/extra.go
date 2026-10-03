package main

// The same-operation Go comparisons for the workloads the original
// fsnotify harness does not cover: kqueue add and remove, glob filtering
// with doublestar, and path prefixes with path/filepath.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bmatcuk/doublestar/v4"
	"github.com/fsnotify/fsnotify"
)

// medianOf runs once until 200 ms of it have been measured (once in smoke)
// and returns the median sample in microseconds.
func medianOf(once func() (time.Duration, error)) (int64, error) {
	var samples []int64
	var total time.Duration
	for len(samples) == 0 || (os.Getenv("BENCH_SMOKE") != "1" && total < 200*time.Millisecond) {
		elapsed, err := once()
		if err != nil {
			return 0, err
		}
		total += elapsed
		samples = append(samples, elapsed.Microseconds())
	}
	return median(samples), nil
}

func median(samples []int64) int64 {
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	return samples[(len(samples)-1)/2]
}

// backendSetup watches the 1,000- and 10,000-file baseline trees
// recursively with fsnotify, which is kqueue on macOS, and removes every
// directory it added: the trees lookout's kqueue backend is timed on. Go
// raises the descriptor limit at start.
func backendSetup(input string) error {
	for _, size := range []string{"small", "medium"} {
		root := filepath.Join(input, "baseline_trees", size)
		var removes []int64
		setup, err := medianOf(func() (time.Duration, error) {
			w, err := fsnotify.NewWatcher()
			if err != nil {
				return 0, err
			}
			defer w.Close()
			started := benchmarkNow()
			if err := addRecursive(w, root); err != nil {
				return 0, err
			}
			elapsed := benchmarkSince(started)
			dirs := w.WatchList()
			started = benchmarkNow()
			for _, dir := range dirs {
				if err := w.Remove(dir); err != nil {
					return 0, err
				}
			}
			removes = append(removes, benchmarkSince(started).Microseconds())
			return elapsed, nil
		})
		if err != nil {
			return err
		}
		metric("setup_kqueue_"+size, "setup_time", setup, "us")
		metric("remove_kqueue_"+size, "remove_time", median(removes), "us")
	}
	return nil
}

func subjects(input, root string, outside bool) ([]string, error) {
	names, err := lines(filepath.Join(input, "paths.txt"))
	if err != nil {
		return nil, err
	}
	var list []string
	for _, name := range names {
		list = append(list, filepath.Join(root, name))
	}
	if outside {
		for _, name := range names {
			list = append(list, filepath.Join(root+"x", name))
		}
	}
	return list, nil
}

// filterWork matches every path of the setup tree, made relative to the
// root as lookout's filter does, against lookout's ignore patterns spelled
// for doublestar.
func filterWork(input, root string) error {
	list, err := subjects(input, root, false)
	if err != nil {
		return err
	}
	// doublestar's trailing "/**" also matches the directory itself, which
	// lookout's does not: "/**/*" names only what is below it.
	patterns := []string{"**/d001?", "**/d001?/**", "**/*7.txt", "d009?/**/*"}
	excluded := 0
	us, err := medianOf(func() (time.Duration, error) {
		count := 0
		started := benchmarkNow()
		for _, subject := range list {
			rest, err := filepath.Rel(root, subject)
			if err != nil {
				return 0, err
			}
			for _, pattern := range patterns {
				if doublestar.MatchUnvalidated(pattern, rest) {
					count++
					break
				}
			}
		}
		elapsed := benchmarkSince(started)
		excluded = count
		return elapsed, nil
	})
	if err != nil {
		return err
	}
	metric("filter", "excludes_time", us, "us")
	metric("filter", "excluded", excluded, "records")
	metric("filter", "paths", len(list), "records")
	return nil
}

// pathWork is filepath.Rel, and a prefix test at a separator, over the
// setup tree's paths and as many beside it.
func pathWork(input, root string) error {
	list, err := subjects(input, root, true)
	if err != nil {
		return err
	}
	inside, bytes := 0, 0
	relative, err := medianOf(func() (time.Duration, error) {
		count, total := 0, 0
		started := benchmarkNow()
		for _, subject := range list {
			rest, err := filepath.Rel(root, subject)
			if err == nil && rest != ".." && !strings.HasPrefix(rest, "../") {
				count++
				if rest != "." {
					total += len(rest)
				}
			}
		}
		elapsed := benchmarkSince(started)
		inside, bytes = count, total
		return elapsed, nil
	})
	if err != nil {
		return err
	}
	withinCount := 0
	within, err := medianOf(func() (time.Duration, error) {
		count := 0
		started := benchmarkNow()
		for _, subject := range list {
			if subject == root || strings.HasPrefix(subject, root+string(filepath.Separator)) {
				count++
			}
		}
		elapsed := benchmarkSince(started)
		withinCount = count
		return elapsed, nil
	})
	if err != nil {
		return err
	}
	if withinCount != inside {
		fail(os.ErrInvalid)
	}
	metric("path", "relative_time", relative, "us")
	metric("path", "within_time", within, "us")
	metric("path", "inside", inside, "records")
	metric("path", "relative_bytes", bytes, "bytes")
	metric("path", "paths", len(list), "records")
	return nil
}
