mod bench;

fn main() {
    if let Err(error) = bench::run(bench::Mode::Raw) {
        eprintln!("notify raw benchmark: {error}");
        std::process::exit(1);
    }
}
