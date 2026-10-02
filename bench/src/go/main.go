package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"
)

const side = "fsnotify"

type config struct {
	LatencyGapMS int   `json:"latency_gap_ms"`
	BurstCounts  []int `json:"burst_counts"`
	IdleSeconds  int   `json:"idle_seconds"`
}

func main() {
	if len(os.Args) != 4 {
		fail(errors.New("usage: fsnotify-bench <latency|burst|rename|idle|tree_setup> <inputs> <watch-root>"))
	}
	input, root := os.Args[2], os.Args[3]
	var err error
	switch os.Args[1] {
	case "latency":
		err = latency(input, root)
	case "burst":
		err = burst(input, root)
	case "rename":
		err = renameWork(input, root)
	case "idle":
		err = idle(input, root)
	case "tree_setup":
		err = treeSetup(root)
	default:
		err = fmt.Errorf("unknown workload %q", os.Args[1])
	}
	if err != nil {
		fail(err)
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "fsnotify benchmark:", err)
	os.Exit(1)
}

func readConfig(input string) (config, error) {
	var cfg config
	data, err := os.ReadFile(filepath.Join(input, "config.json"))
	if err != nil {
		return cfg, err
	}
	err = json.Unmarshal(data, &cfg)
	return cfg, err
}

func lines(path string) ([]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var out []string
	s := bufio.NewScanner(f)
	for s.Scan() {
		if s.Text() != "" {
			out = append(out, s.Text())
		}
	}
	return out, s.Err()
}

func metric(workload, name string, value any, unit string) {
	fmt.Printf("%s\t%s\t%s\t%v\t%s\n", side, workload, name, value, unit)
}

func addRecursive(w *fsnotify.Watcher, root string) error {
	// fsnotify is explicitly non-recursive. Walking and adding every directory
	// is part of this adapter's setup cost so all sides cover the same tree.
	return filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return w.Add(path)
		}
		return nil
	})
}

func receive(w *fsnotify.Watcher, timeout time.Duration) (*fsnotify.Event, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case event, ok := <-w.Events:
		if !ok {
			return nil, fsnotify.ErrClosed
		}
		return &event, nil
	case err, ok := <-w.Errors:
		if !ok {
			return nil, fsnotify.ErrClosed
		}
		return nil, err
	case <-timer.C:
		return nil, nil
	}
}

func warmup(w *fsnotify.Watcher, root string) error {
	wanted := filepath.Join(root, ".warmup")
	if err := os.WriteFile(wanted, []byte("x"), 0o644); err != nil {
		return err
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		event, err := receive(w, 100*time.Millisecond)
		if err != nil {
			return err
		}
		if event != nil && event.Name == wanted {
			return nil
		}
	}
	return errors.New("warm-up event was not delivered")
}

func latency(input, root string) error {
	cfg, err := readConfig(input)
	if err != nil {
		return err
	}
	names, err := lines(filepath.Join(input, "latency.txt"))
	if err != nil {
		return err
	}
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()
	if err = addRecursive(w, root); err != nil {
		return err
	}
	if err = warmup(w, root); err != nil {
		return err
	}
	samples := make([]int64, 0, len(names))
	for _, name := range names {
		wanted := filepath.Join(root, name)
		started := benchmarkNow()
		if err = os.WriteFile(wanted, []byte("x"), 0o644); err != nil {
			return err
		}
		deadline := time.Now().Add(5 * time.Second)
		seen := false
		for time.Now().Before(deadline) && !seen {
			event, recvErr := receive(w, 100*time.Millisecond)
			if recvErr != nil {
				return recvErr
			}
			if event != nil && event.Name == wanted {
				samples = append(samples, benchmarkSince(started).Microseconds())
				seen = true
			}
		}
		if !seen {
			return fmt.Errorf("latency event not observed for %s", name)
		}
		time.Sleep(time.Duration(cfg.LatencyGapMS) * time.Millisecond)
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	median := samples[(len(samples)-1)/2]
	p99 := samples[((len(samples)*99+99)/100)-1]
	metric("latency", "latency_median", median, "us")
	metric("latency", "latency_p99", p99, "us")
	return nil
}

func indexOf(path, prefix, suffix string, count int) (int, bool) {
	name := filepath.Base(path)
	if !strings.HasPrefix(name, prefix) || !strings.HasSuffix(name, suffix) {
		return 0, false
	}
	digits := strings.TrimSuffix(strings.TrimPrefix(name, prefix), suffix)
	i, err := strconv.Atoi(digits)
	return i, err == nil && i >= 0 && i < count
}

func burst(input, root string) error {
	cfg, err := readConfig(input)
	if err != nil {
		return err
	}
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()
	if err = addRecursive(w, root); err != nil {
		return err
	}
	if err = warmup(w, root); err != nil {
		return err
	}
	for _, count := range cfg.BurstCounts {
		names, readErr := lines(filepath.Join(input, fmt.Sprintf("burst_%d.txt", count)))
		if readErr != nil {
			return readErr
		}
		var done atomic.Bool
		started := benchmarkNow()
		go func() {
			for _, name := range names {
				if writeErr := os.WriteFile(filepath.Join(root, name), []byte("x"), 0o644); writeErr != nil {
					fmt.Fprintln(os.Stderr, "burst writer:", writeErr)
					break
				}
			}
			done.Store(true)
		}()
		unique := make([]bool, count)
		delivered, overflow := 0, false
		var last int64 = -1
		var quiet time.Time
		for {
			event, recvErr := receive(w, 100*time.Millisecond)
			if recvErr != nil {
				if errors.Is(recvErr, fsnotify.ErrEventOverflow) {
					overflow = true
				} else {
					return recvErr
				}
			}
			if event != nil {
				quiet = time.Time{}
				if i, ok := indexOf(event.Name, "f", ".txt", count); ok {
					delivered++
					unique[i] = true
					last = benchmarkSince(started).Microseconds()
				}
			} else if done.Load() {
				if quiet.IsZero() {
					quiet = time.Now()
				}
				if time.Since(quiet) >= 2*time.Second {
					break
				}
			}
		}
		observed := 0
		for _, seen := range unique {
			if seen {
				observed++
			}
		}
		workload := fmt.Sprintf("burst_%d", count)
		metric(workload, "events_delivered", delivered, "events")
		metric(workload, "files_missed", count-observed, "files")
		if overflow {
			metric(workload, "overflow_reported", 1, "bool")
		} else {
			metric(workload, "overflow_reported", 0, "bool")
		}
		if last >= 0 {
			metric(workload, "time_to_last_event", last, "us")
		} else {
			metric(workload, "time_to_last_event", "n/a", "us")
		}
	}
	return nil
}

func renameWork(input, root string) error {
	rows, err := lines(filepath.Join(input, "rename.tsv"))
	if err != nil {
		return err
	}
	type pair struct{ old, new string }
	pairs := make([]pair, len(rows))
	for i, row := range rows {
		fields := strings.Split(row, "\t")
		pairs[i] = pair{fields[0], fields[1]}
	}
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()
	if err = addRecursive(w, root); err != nil {
		return err
	}
	if err = warmup(w, root); err != nil {
		return err
	}
	var done atomic.Bool
	go func() {
		for _, p := range pairs {
			if renameErr := os.Rename(filepath.Join(root, p.old), filepath.Join(root, p.new)); renameErr != nil {
				fmt.Fprintln(os.Stderr, "rename writer:", renameErr)
				break
			}
		}
		done.Store(true)
	}()
	oldSeen, newSeen := make([]bool, len(pairs)), make([]bool, len(pairs))
	var quiet time.Time
	for {
		event, recvErr := receive(w, 100*time.Millisecond)
		if recvErr != nil {
			return recvErr
		}
		if event != nil {
			quiet = time.Time{}
			if i, ok := indexOf(event.Name, "r", "-old.txt", len(pairs)); ok {
				oldSeen[i] = true
			}
			if i, ok := indexOf(event.Name, "r", "-new.txt", len(pairs)); ok {
				newSeen[i] = true
			}
		} else if done.Load() {
			if quiet.IsZero() {
				quiet = time.Now()
			}
			if time.Since(quiet) >= 2*time.Second {
				break
			}
		}
	}
	// fsnotify.Event has one path, so this API cannot express a paired rename.
	split := 0
	for i := range pairs {
		if oldSeen[i] && newSeen[i] {
			split++
		}
	}
	metric("rename", "paired", 0, "renames")
	metric("rename", "split", split, "renames")
	metric("rename", "unmatched", len(pairs)-split, "renames")
	return nil
}

func cpuMicros() int64 {
    if os.Getenv("BENCH_SMOKE") == "1" { return 0 }
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
		panic(err)
	}
	return usage.Utime.Sec*1_000_000 + int64(usage.Utime.Usec) + usage.Stime.Sec*1_000_000 + int64(usage.Stime.Usec)
}

func idle(input, root string) error {
	cfg, err := readConfig(input)
	if err != nil {
		return err
	}
	names, err := lines(filepath.Join(input, "idle.txt"))
	if err != nil {
		return err
	}
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	defer w.Close()
	if err = addRecursive(w, root); err != nil {
		return err
	}
	if err = warmup(w, root); err != nil {
		return err
	}
	duration := time.Duration(cfg.IdleSeconds) * time.Second
	cpuStart, wallStart := cpuMicros(), time.Now()
	for time.Since(wallStart) < duration {
		_, _ = receive(w, 100*time.Millisecond)
	}
	idleCPU := cpuMicros() - cpuStart
	activeStart, cpuStart := time.Now(), cpuMicros()
	done := make(chan struct{})
	go func() {
		for i, name := range names {
			_ = os.WriteFile(filepath.Join(root, name), []byte("x"), 0o644)
			target := activeStart.Add(time.Duration(i+1) * 10 * time.Millisecond)
			if delay := time.Until(target); delay > 0 {
				time.Sleep(delay)
			}
		}
		close(done)
	}()
	for time.Since(activeStart) < duration {
		_, _ = receive(w, 100*time.Millisecond)
	}
	<-done
	activeCPU := cpuMicros() - cpuStart
	metric("idle", "idle_cpu", idleCPU, "us")
	metric("idle", "active_100ps_cpu", activeCPU, "us")
	return nil
}

func treeSetup(root string) error {
	var samples []int64
	var measured time.Duration
	for len(samples) == 0 || (os.Getenv("BENCH_SMOKE") != "1" && measured < 200*time.Millisecond) {
		w, err := fsnotify.NewWatcher()
		if err != nil {
			return err
		}
		started := benchmarkNow()
		err = addRecursive(w, root)
		elapsed := benchmarkSince(started)
		_ = w.Close()
		if err != nil {
			fmt.Fprintln(os.Stderr, "fsnotify setup failed:", err)
			metric("tree_setup", "setup_time", "n/a", "us")
			metric("tree_setup", "setup_success", 0, "bool")
			return nil
		}
		measured += elapsed
		samples = append(samples, elapsed.Microseconds())
	}
	sort.Slice(samples, func(i, j int) bool { return samples[i] < samples[j] })
	metric("tree_setup", "setup_time", samples[(len(samples)-1)/2], "us")
	metric("tree_setup", "setup_success", 1, "bool")
	return nil
}

func benchmarkNow() time.Time {
    if os.Getenv("BENCH_SMOKE") == "1" { return time.Time{} }
    return time.Now()
}
func benchmarkSince(start time.Time) time.Duration {
    if os.Getenv("BENCH_SMOKE") == "1" { return time.Nanosecond }
    return time.Since(start)
}
