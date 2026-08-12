use std::ffi::OsString;
use std::process;

fn main() {
    let context = match hephaestus::Context::from_environment() {
        Ok(context) => context,
        Err(err) => {
            eprintln!("{err}");
            process::exit(1);
        }
    };

    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    let result = hephaestus::run(&context, &args);

    match &result {
        Ok(output) => {
            if let Some(stderr) = &output.stderr {
                eprintln!("{stderr}");
            }
            if let Some(stdout) = &output.stdout {
                println!("{stdout}");
            }
        }
        Err(err) => {
            eprintln!("{err}");
        }
    }

    process::exit(hephaestus::exit_code_for_result(&result));
}
