mod bench;

fn main() {
    if let Err(error) = bench::run(bench::Mode::Debounced) {
        eprintln!("notify debounced benchmark: {error}");
        std::process::exit(1);
    }
}
