use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use notify_debouncer_full::{new_debouncer, DebounceEventResult, Debouncer, RecommendedCache};
use std::collections::{HashMap, HashSet};
use std::error::Error;
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::{Duration, Instant};

const RECEIVE_SLICE: Duration = Duration::from_millis(100);
const QUIET_AFTER_WRITER: Duration = Duration::from_secs(2);

#[allow(dead_code)]
#[derive(Clone, Copy)]
pub enum Mode {
    Raw,
    Debounced,
}

impl Mode {
    fn side(self) -> &'static str {
        match self {
            Self::Raw => "notify",
            Self::Debounced => "notify_debouncer_full",
        }
    }
}

trait EventSource {
    fn watch(&mut self, path: &Path) -> Result<(), Box<dyn Error>>;
    fn receive(&mut self, timeout: Duration) -> Vec<Event>;
}

struct RawSource {
    watcher: RecommendedWatcher,
    rx: mpsc::Receiver<notify::Result<Event>>,
}

impl EventSource for RawSource {
    fn watch(&mut self, path: &Path) -> Result<(), Box<dyn Error>> {
        self.watcher.watch(path, RecursiveMode::Recursive)?;
        Ok(())
    }

    fn receive(&mut self, timeout: Duration) -> Vec<Event> {
        match self.rx.recv_timeout(timeout) {
            Ok(Ok(event)) => vec![event],
            Ok(Err(error)) => {
                eprintln!("notify event error: {error}");
                Vec::new()
            }
            Err(_) => Vec::new(),
        }
    }
}

struct DebouncedSource {
    watcher: Debouncer<RecommendedWatcher, RecommendedCache>,
    rx: mpsc::Receiver<DebounceEventResult>,
}

impl EventSource for DebouncedSource {
    fn watch(&mut self, path: &Path) -> Result<(), Box<dyn Error>> {
        self.watcher.watch(path, RecursiveMode::Recursive)?;
        Ok(())
    }

    fn receive(&mut self, timeout: Duration) -> Vec<Event> {
        match self.rx.recv_timeout(timeout) {
            Ok(Ok(events)) => events.into_iter().map(|event| event.event).collect(),
            Ok(Err(errors)) => {
                for error in errors {
                    eprintln!("notify debouncer event error: {error}");
                }
                Vec::new()
            }
            Err(_) => Vec::new(),
        }
    }
}

fn source(mode: Mode) -> Result<Box<dyn EventSource>, Box<dyn Error>> {
    match mode {
        Mode::Raw => {
            let (tx, rx) = mpsc::channel();
            let watcher = notify::recommended_watcher(tx)?;
            Ok(Box::new(RawSource { watcher, rx }))
        }
        Mode::Debounced => {
            let (tx, rx) = mpsc::channel();
            // Ten milliseconds is the smallest practical window here and is
            // disclosed in README.md. It is an intentional semantic variant.
            let watcher = new_debouncer(
                Duration::from_millis(10),
                Some(Duration::from_millis(2)),
                tx,
            )?;
            Ok(Box::new(DebouncedSource { watcher, rx }))
        }
    }
}

pub fn run(mode: Mode) -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        return Err(
            "usage: PROGRAM <latency|burst|rename|idle|tree_setup> <inputs> <watch-root>".into(),
        );
    }
    let input = Path::new(&args[2]);
    let root = Path::new(&args[3]);
    match args[1].as_str() {
        "latency" => latency(mode, input, root),
        "burst" => burst(mode, input, root),
        "rename" => rename(mode, input, root),
        "idle" => idle(mode, input, root),
        "tree_setup" => tree_setup(mode, root),
        _ => Err(format!("unknown workload: {}", args[1]).into()),
    }
}

fn lines(path: &Path) -> Result<Vec<String>, Box<dyn Error>> {
    Ok(fs::read_to_string(path)?
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect())
}

fn config_number(input: &Path, key: &str) -> Result<u64, Box<dyn Error>> {
    let text = fs::read_to_string(input.join("config.json"))?;
    let needle = format!("\"{key}\":");
    let start = text.find(&needle).ok_or("missing config key")? + needle.len();
    let digits: String = text[start..]
        .chars()
        .skip_while(|ch| ch.is_whitespace())
        .take_while(|ch| ch.is_ascii_digit())
        .collect();
    Ok(digits.parse()?)
}

fn print_metric(
    side: &str,
    workload: &str,
    metric: &str,
    value: impl std::fmt::Display,
    unit: &str,
) {
    println!("{side}\t{workload}\t{metric}\t{value}\t{unit}");
}

fn warm_up(source: &mut dyn EventSource, root: &Path) -> Result<(), Box<dyn Error>> {
    // A write made as the watch starts can precede the event stream (FSEvents
    // drops what happens before its stream runs), so write again until one
    // arrives. Warm-up is not measured.
    let wanted = root.join(".warmup");
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut written = 0u32;
    while Instant::now() < deadline {
        fs::write(&wanted, written.to_string())?;
        written += 1;
        if source
            .receive(RECEIVE_SLICE)
            .iter()
            .any(|event| event.paths.iter().any(|p| p == &wanted))
        {
            return Ok(());
        }
    }
    Err("warm-up event was not delivered".into())
}

fn latency(mode: Mode, input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let names = lines(&input.join("latency.txt"))?;
    let gap = Duration::from_millis(config_number(input, "latency_gap_ms")?);
    let mut source = source(mode)?;
    source.watch(root)?;
    warm_up(source.as_mut(), root)?;
    let mut samples = Vec::with_capacity(names.len());
    for name in names {
        let wanted = root.join(&name);
        let started = BenchmarkInstant::now();
        fs::write(&wanted, b"x")?;
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut seen = false;
        while Instant::now() < deadline && !seen {
            for event in source.receive(RECEIVE_SLICE) {
                if event.paths.iter().any(|path| path == &wanted) {
                    samples.push(started.elapsed().as_micros() as u64);
                    seen = true;
                    break;
                }
            }
        }
        if !seen {
            return Err(format!("latency event not observed for {name}").into());
        }
        thread::sleep(gap);
    }
    samples.sort_unstable();
    let median = samples[(samples.len() - 1) / 2];
    let p99_index = ((samples.len() * 99 + 99) / 100).saturating_sub(1);
    print_metric(mode.side(), "latency", "latency_median", median, "us");
    print_metric(
        mode.side(),
        "latency",
        "latency_p99",
        samples[p99_index],
        "us",
    );
    Ok(())
}

fn matching_index(path: &Path, prefix: &str, suffix: &str, count: usize) -> Option<usize> {
    let name = path.file_name()?.to_str()?;
    let digits = name.strip_prefix(prefix)?.strip_suffix(suffix)?;
    let index = digits.parse::<usize>().ok()?;
    (index < count).then_some(index)
}

fn burst(mode: Mode, input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let cfg = fs::read_to_string(input.join("config.json"))?;
    let marker = "\"burst_counts\":";
    let tail = &cfg[cfg.find(marker).ok_or("missing burst_counts")? + marker.len()..];
    let inside = tail
        .split('[')
        .nth(1)
        .ok_or("bad burst_counts")?
        .split(']')
        .next()
        .ok_or("bad burst_counts")?;
    let counts: Vec<usize> = inside
        .split(',')
        .map(|v| v.trim().parse())
        .collect::<Result<_, _>>()?;

    let mut source = source(mode)?;
    source.watch(root)?;
    warm_up(source.as_mut(), root)?;
    for count in counts {
        let names = lines(&input.join(format!("burst_{count}.txt")))?;
        let writer_root = root.to_owned();
        let done = Arc::new(AtomicBool::new(false));
        let writer_done = done.clone();
        let started = BenchmarkInstant::now();
        let writer = thread::spawn(move || {
            for name in names {
                if let Err(error) = fs::write(writer_root.join(name), b"x") {
                    eprintln!("burst writer: {error}");
                    break;
                }
            }
            writer_done.store(true, Ordering::Release);
        });

        let mut unique = vec![false; count];
        let mut delivered = 0usize;
        let mut overflow = false;
        let mut last = None;
        let mut quiet_since = None;
        loop {
            let events = source.receive(RECEIVE_SLICE);
            if events.is_empty() {
                if done.load(Ordering::Acquire) {
                    let quiet = quiet_since.get_or_insert_with(Instant::now);
                    if quiet.elapsed() >= QUIET_AFTER_WRITER {
                        break;
                    }
                }
            } else {
                quiet_since = None;
                for event in events {
                    overflow |= event.need_rescan();
                    for path in &event.paths {
                        if let Some(index) = matching_index(path, "f", ".txt", count) {
                            delivered += 1;
                            unique[index] = true;
                            last = Some(started.elapsed().as_micros());
                        }
                    }
                }
            }
        }
        writer.join().map_err(|_| "burst writer panicked")?;
        let observed = unique.into_iter().filter(|seen| *seen).count();
        let workload = format!("burst_{count}");
        print_metric(
            mode.side(),
            &workload,
            "events_delivered",
            delivered,
            "events",
        );
        print_metric(
            mode.side(),
            &workload,
            "files_missed",
            count - observed,
            "files",
        );
        print_metric(
            mode.side(),
            &workload,
            "overflow_reported",
            u8::from(overflow),
            "bool",
        );
        match last {
            Some(value) => print_metric(mode.side(), &workload, "time_to_last_event", value, "us"),
            None => println!("{}\t{}\ttime_to_last_event\tn/a\tus", mode.side(), workload),
        }
    }
    Ok(())
}

fn rename(mode: Mode, input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let pairs: Vec<(String, String)> = lines(&input.join("rename.tsv"))?
        .into_iter()
        .map(|line| {
            let (old, new) = line.split_once('\t').expect("generated rename line");
            (old.to_owned(), new.to_owned())
        })
        .collect();
    let count = pairs.len();
    let mut source = source(mode)?;
    source.watch(root)?;
    warm_up(source.as_mut(), root)?;
    let writer_root = root.to_owned();
    let done = Arc::new(AtomicBool::new(false));
    let writer_done = done.clone();
    let writer = thread::spawn(move || {
        for (old, new) in pairs {
            if let Err(error) = fs::rename(writer_root.join(old), writer_root.join(new)) {
                eprintln!("rename writer: {error}");
                break;
            }
        }
        writer_done.store(true, Ordering::Release);
    });
    let mut old_seen = vec![false; count];
    let mut new_seen = vec![false; count];
    let mut paired = vec![false; count];
    let mut tracker_old: HashMap<usize, usize> = HashMap::new();
    let mut tracker_new: HashMap<usize, usize> = HashMap::new();
    let mut quiet_since = None;
    loop {
        let events = source.receive(RECEIVE_SLICE);
        if events.is_empty() {
            if done.load(Ordering::Acquire) {
                let quiet = quiet_since.get_or_insert_with(Instant::now);
                if quiet.elapsed() >= QUIET_AFTER_WRITER {
                    break;
                }
            }
        } else {
            quiet_since = None;
            for event in events {
                let olds: HashSet<_> = event
                    .paths
                    .iter()
                    .filter_map(|p| matching_index(p, "r", "-old.txt", count))
                    .collect();
                let news: HashSet<_> = event
                    .paths
                    .iter()
                    .filter_map(|p| matching_index(p, "r", "-new.txt", count))
                    .collect();
                for &index in &olds {
                    old_seen[index] = true;
                }
                for &index in &news {
                    new_seen[index] = true;
                }
                for index in olds.intersection(&news) {
                    paired[*index] = true;
                }
                if let Some(tracker) = event.tracker() {
                    for &index in &olds {
                        tracker_old.insert(tracker, index);
                        if tracker_new.get(&tracker) == Some(&index) {
                            paired[index] = true;
                        }
                    }
                    for &index in &news {
                        tracker_new.insert(tracker, index);
                        if tracker_old.get(&tracker) == Some(&index) {
                            paired[index] = true;
                        }
                    }
                }
            }
        }
    }
    writer.join().map_err(|_| "rename writer panicked")?;
    let paired_count = paired.iter().filter(|v| **v).count();
    let split_count = (0..count)
        .filter(|&i| !paired[i] && old_seen[i] && new_seen[i])
        .count();
    print_metric(mode.side(), "rename", "paired", paired_count, "renames");
    print_metric(mode.side(), "rename", "split", split_count, "renames");
    print_metric(
        mode.side(),
        "rename",
        "unmatched",
        count - paired_count - split_count,
        "renames",
    );
    Ok(())
}

fn cpu_micros() -> u64 {
    if smoke() { return 0; }
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        assert_eq!(libc::getrusage(libc::RUSAGE_SELF, &mut usage), 0);
        let user = usage.ru_utime.tv_sec as u64 * 1_000_000 + usage.ru_utime.tv_usec as u64;
        let system = usage.ru_stime.tv_sec as u64 * 1_000_000 + usage.ru_stime.tv_usec as u64;
        user + system
    }
}

fn idle(mode: Mode, input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let duration = Duration::from_secs(config_number(input, "idle_seconds")?);
    let names = lines(&input.join("idle.txt"))?;
    let mut source = source(mode)?;
    source.watch(root)?;
    warm_up(source.as_mut(), root)?;

    let cpu_start = cpu_micros();
    let wall_start = Instant::now();
    while wall_start.elapsed() < duration {
        let _ = source.receive(RECEIVE_SLICE);
    }
    let idle_cpu = cpu_micros() - cpu_start;

    let writer_root = root.to_owned();
    let active_start = Instant::now();
    let cpu_start = cpu_micros();
    let writer = thread::spawn(move || {
        for (index, name) in names.into_iter().enumerate() {
            let target = active_start + Duration::from_millis((index as u64 + 1) * 10);
            let _ = fs::write(writer_root.join(name), b"x");
            if let Some(left) = target.checked_duration_since(Instant::now()) {
                thread::sleep(left);
            }
        }
    });
    while active_start.elapsed() < duration {
        let _ = source.receive(RECEIVE_SLICE);
    }
    writer.join().map_err(|_| "active writer panicked")?;
    let active_cpu = cpu_micros() - cpu_start;
    print_metric(mode.side(), "idle", "idle_cpu", idle_cpu, "us");
    print_metric(mode.side(), "idle", "active_100ps_cpu", active_cpu, "us");
    Ok(())
}

fn tree_setup(mode: Mode, root: &Path) -> Result<(), Box<dyn Error>> {
    let mut samples = Vec::new();
    let mut measured = Duration::ZERO;
    while samples.is_empty() || (!smoke() && measured < Duration::from_millis(200)) {
        let mut source = source(mode)?;
        let started = BenchmarkInstant::now();
        if let Err(error) = source.watch(root) {
            eprintln!("{} setup failed: {error}", mode.side());
            println!("{}\ttree_setup\tsetup_time\tn/a\tus", mode.side());
            print_metric(mode.side(), "tree_setup", "setup_success", 0, "bool");
            return Ok(());
        }
        let elapsed = started.elapsed();
        measured += elapsed;
        samples.push(elapsed.as_micros());
    }
    samples.sort_unstable();
    print_metric(
        mode.side(),
        "tree_setup",
        "setup_time",
        samples[(samples.len() - 1) / 2],
        "us",
    );
    print_metric(mode.side(), "tree_setup", "setup_success", 1, "bool");
    Ok(())
}

fn smoke() -> bool { std::env::var("BENCH_SMOKE").as_deref() == Ok("1") }

struct BenchmarkInstant(Option<Instant>);
impl BenchmarkInstant {
    fn now() -> Self { Self(if smoke() { None } else { Some(Instant::now()) }) }
    fn elapsed(&self) -> Duration { self.0.map_or(Duration::from_nanos(1), |start| start.elapsed()) }
}
