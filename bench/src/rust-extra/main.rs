//! The same-operation Rust comparisons for the workloads the original
//! notify harness does not cover: the FSEvents and poll backends' add and
//! remove, polling cost, glob filtering and path prefixes. notify's kqueue
//! backend is a build feature that replaces its FSEvents one, so it is in
//! src/rust-kqueue.

use globset::{GlobBuilder, GlobSet, GlobSetBuilder};
use notify::{Config, FsEventWatcher, PollWatcher, RecursiveMode, Watcher};
use std::error::Error;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

fn main() {
    if let Err(error) = run() {
        eprintln!("notify extra benchmark: {error}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn Error>> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 {
        return Err("usage: PROGRAM <backend_setup|poll_cpu|filter|path> <inputs> <root>".into());
    }
    let input = Path::new(&args[2]);
    let root = Path::new(&args[3]);
    match args[1].as_str() {
        "backend_setup" => backend_setup(root),
        "poll_cpu" => poll_cpu(input, root),
        "filter" => filter(input, root),
        "path" => path(input, root),
        other => Err(format!("unknown workload: {other}").into()),
    }
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

mod common;
use common::{cycle, median_of, metric, raise_descriptor_limit, smoke, Clock};

/// The FSEvents and poll backends' recursive watch and unwatch of the
/// setup tree. The poll watcher's interval is an hour, so it does not scan
/// between the two.
fn backend_setup(root: &Path) -> Result<(), Box<dyn Error>> {
    raise_descriptor_limit();
    cycle("fsevents", root, || FsEventWatcher::new(|_| {}, Config::default()))?;
    cycle("poll", root, || {
        PollWatcher::new(|_| {}, Config::default().with_poll_interval(Duration::from_secs(3600)))
    })?;
    Ok(())
}

fn cpu_micros() -> u128 {
    if smoke() {
        return 0;
    }
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        let micros = |t: libc::timeval| t.tv_sec as u128 * 1_000_000 + t.tv_usec as u128;
        micros(usage.ru_utime) + micros(usage.ru_stime)
    }
}

/// The CPU a poll watcher over the setup tree costs at a 100 ms interval,
/// over the window lookout's poll backend is measured over.
fn poll_cpu(input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let window = config_number(input, "poll_window_ms")?;
    let (tx, rx) = std::sync::mpsc::channel();
    let mut watcher = PollWatcher::new(tx, Config::default().with_poll_interval(Duration::from_millis(100)))?;
    watcher.watch(root, RecursiveMode::Recursive)?;
    let cpu = cpu_micros();
    std::thread::sleep(Duration::from_millis(window));
    let cpu = cpu_micros() - cpu;
    drop(watcher);
    let events = rx.try_iter().filter(|event| event.is_ok()).count();
    metric("poll_cpu", "cpu", cpu, "us");
    metric("poll_cpu", "events", events, "events");
    Ok(())
}

fn subjects(input: &Path, root: &Path, outside: bool) -> Result<Vec<PathBuf>, Box<dyn Error>> {
    let names: Vec<String> = fs::read_to_string(input.join("paths.txt"))?
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect();
    let mut list: Vec<PathBuf> = names.iter().map(|name| root.join(name)).collect();
    if outside {
        let mut sibling = root.as_os_str().to_owned();
        sibling.push("x");
        let sibling = PathBuf::from(sibling);
        list.extend(names.iter().map(|name| sibling.join(name)));
    }
    Ok(list)
}

/// lookout's ignore patterns, spelled for globset: a pattern with no
/// separator also matches the last component at any depth, and a matched
/// directory takes everything below it.
fn glob_set() -> Result<GlobSet, Box<dyn Error>> {
    let mut builder = GlobSetBuilder::new();
    for pattern in ["**/d001?", "**/d001?/**", "**/*7.txt", "d009?/**"] {
        builder.add(GlobBuilder::new(pattern).literal_separator(true).build()?);
    }
    Ok(builder.build()?)
}

/// globset over every path of the setup tree, each made relative to the
/// root first, as lookout's filter does.
fn filter(input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let list = subjects(input, root, false)?;
    let set = glob_set()?;
    let mut excluded = 0;
    let us = median_of(|| {
        let clock = Clock::start();
        let mut count = 0;
        for subject in &list {
            if let Ok(rest) = subject.strip_prefix(root) {
                count += usize::from(set.is_match(rest));
            }
        }
        let us = clock.micros();
        excluded = count;
        Ok(us)
    })?;
    metric("filter", "excludes_time", us, "us");
    metric("filter", "excluded", excluded, "records");
    metric("filter", "paths", list.len(), "records");
    Ok(())
}

/// `Path::strip_prefix` and `Path::starts_with` over the setup tree's paths
/// and as many beside it.
fn path(input: &Path, root: &Path) -> Result<(), Box<dyn Error>> {
    let list = subjects(input, root, true)?;
    let (mut inside, mut bytes) = (0, 0);
    let relative = median_of(|| {
        let clock = Clock::start();
        let (mut count, mut total) = (0, 0);
        for subject in &list {
            if let Ok(rest) = subject.strip_prefix(root) {
                count += 1;
                total += rest.as_os_str().len();
            }
        }
        let us = clock.micros();
        (inside, bytes) = (count, total);
        Ok(us)
    })?;
    let mut within_count = 0;
    let within = median_of(|| {
        let clock = Clock::start();
        let count = list.iter().filter(|subject| subject.starts_with(root)).count();
        let us = clock.micros();
        within_count = count;
        Ok(us)
    })?;
    if within_count != inside {
        return Err("strip_prefix and starts_with disagree".into());
    }
    metric("path", "relative_time", relative, "us");
    metric("path", "within_time", within, "us");
    metric("path", "inside", inside, "records");
    metric("path", "relative_bytes", bytes, "bytes");
    metric("path", "paths", list.len(), "records");
    Ok(())
}
