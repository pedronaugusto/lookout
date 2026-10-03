//! What both extra Rust comparison binaries share: the row format, the
//! smoke clock, sample medians and the watch/unwatch cycle.

use notify::{RecursiveMode, Watcher};
use std::error::Error;
use std::path::Path;
use std::time::Instant;

pub fn smoke() -> bool {
    std::env::var("BENCH_SMOKE").as_deref() == Ok("1")
}

pub fn metric(workload: &str, name: &str, value: impl std::fmt::Display, unit: &str) {
    println!("rust\t{workload}\t{name}\t{value}\t{unit}");
}

pub struct Clock(Option<Instant>);
impl Clock {
    pub fn start() -> Self {
        Self(if smoke() { None } else { Some(Instant::now()) })
    }
    pub fn micros(&self) -> u128 {
        self.0.map_or(1, |start| start.elapsed().as_micros())
    }
}

/// Runs `once` until 200 ms of it have been measured (once in smoke) and
/// returns the median sample, in microseconds.
pub fn median_of(mut once: impl FnMut() -> Result<u128, Box<dyn Error>>) -> Result<u128, Box<dyn Error>> {
    let mut samples = Vec::new();
    let mut total = 0;
    while samples.is_empty() || (!smoke() && total < 200_000) {
        let us = once()?;
        total += us;
        samples.push(us);
    }
    Ok(median(&mut samples))
}

pub fn median(samples: &mut [u128]) -> u128 {
    samples.sort_unstable();
    samples[(samples.len() - 1) / 2]
}

/// kqueue holds a descriptor per watched file and directory; raise the soft
/// limit as Go does at start, capped where macOS caps it.
pub fn raise_descriptor_limit() {
    // SAFETY: plain libc calls on locals.
    unsafe {
        let mut limit: libc::rlimit = std::mem::zeroed();
        if libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) != 0 {
            return;
        }
        let mut cap: libc::c_int = 0;
        let mut len = std::mem::size_of::<libc::c_int>();
        let name = c"kern.maxfilesperproc";
        let read = libc::sysctlbyname(name.as_ptr(), (&mut cap as *mut libc::c_int).cast(), &mut len, std::ptr::null_mut(), 0);
        limit.rlim_cur = if read == 0 && cap > 0 { limit.rlim_max.min(cap as libc::rlim_t) } else { limit.rlim_max };
        libc::setrlimit(libc::RLIMIT_NOFILE, &limit);
    }
}

/// A recursive watch and unwatch of `root` by fresh watchers until 200 ms
/// of watching have been measured; the medians of both, as `setup_<name>`
/// and `remove_<name>` rows.
pub fn cycle<W: Watcher>(name: &str, root: &Path, make: impl Fn() -> notify::Result<W>) -> Result<(), Box<dyn Error>> {
    let mut removes = Vec::new();
    let setup = median_of(|| {
        let mut watcher = make()?;
        let clock = Clock::start();
        watcher.watch(root, RecursiveMode::Recursive)?;
        let setup = clock.micros();
        let clock = Clock::start();
        watcher.unwatch(root)?;
        removes.push(clock.micros());
        Ok(setup)
    })?;
    metric(&format!("setup_{name}"), "setup_time", setup, "us");
    metric(&format!("remove_{name}"), "remove_time", median(&mut removes), "us");
    Ok(())
}
