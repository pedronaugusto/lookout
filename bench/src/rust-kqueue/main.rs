//! notify's kqueue backend: a recursive watch and unwatch of the 1,000-,
//! 10,000- and 50,000-file baseline trees, the trees lookout's kqueue backend
//! is timed on.

#[path = "../rust-extra/common.rs"]
mod common;

use notify::{Config, KqueueWatcher, Watcher};
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 4 || args[1] != "backend_setup" {
        eprintln!("usage: notify-kqueue-bench backend_setup <inputs> <root>");
        std::process::exit(1);
    }
    common::raise_descriptor_limit();
    for size in ["small", "medium", "large"] {
        let tree = Path::new(&args[2]).join("baseline_trees").join(size);
        let name = format!("kqueue_{size}");
        if let Err(error) = common::cycle(&name, &tree, || KqueueWatcher::new(|_| {}, Config::default())) {
            eprintln!("notify kqueue benchmark: {error}");
            std::process::exit(1);
        }
    }
}
