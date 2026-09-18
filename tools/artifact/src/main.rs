#![forbid(unsafe_code)]
#![deny(warnings, clippy::all)]

use kamu_money_pg_artifact::{
    CandidateTriplet, DevelopmentTriplet, copy_development_to_node, copy_to_node, release_check,
};
use std::env;

fn main() {
    if let Err(error) = run() {
        eprintln!("artifact: {error}");
        std::process::exit(2);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = env::args().skip(1);
    let command =
        arguments.next().ok_or("usage: artifact <release-check|copy-to-node|copy-to-node-dev> ...")?;
    match command.as_str() {
        "release-check" => {
            let directory = one_path(&mut arguments)?;
            let verified = CandidateTriplet::open(directory)?.verify()?;
            release_check(&verified)?;
            println!("release-checked");
        }
        "copy-to-node" => {
            let (directory, node) = path_and_node(&mut arguments)?;
            let verified = CandidateTriplet::open(directory)?.verify()?;
            print_receipt(copy_to_node(&verified, &node)?);
        }
        "copy-to-node-dev" => {
            let (directory, node) = path_and_node(&mut arguments)?;
            let receipt = match CandidateTriplet::open(&directory) {
                Ok(candidate) => copy_to_node(&candidate.verify()?, &node)?,
                Err(error) if error.is_manifest_missing() => {
                    let development = DevelopmentTriplet::open_without_manifest(directory)?;
                    copy_development_to_node(&development, &node)?
                }
                Err(error) => return Err(error.into()),
            };
            print_receipt(receipt);
        }
        _ => return Err(format!("unknown artifact command {command:?}").into()),
    }
    Ok(())
}

fn one_path(arguments: &mut impl Iterator<Item = String>) -> Result<String, Box<dyn std::error::Error>> {
    let path = arguments.next().ok_or("artifact directory is required")?;
    no_more(arguments)?;
    Ok(path)
}

fn path_and_node(
    arguments: &mut impl Iterator<Item = String>,
) -> Result<(String, String), Box<dyn std::error::Error>> {
    let path = arguments.next().ok_or("artifact directory is required")?;
    let node = arguments.next().ok_or("container name is required")?;
    no_more(arguments)?;
    Ok((path, node))
}

fn no_more(arguments: &mut impl Iterator<Item = String>) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(argument) = arguments.next() {
        return Err(format!("unexpected argument {argument:?}").into());
    }
    Ok(())
}

fn print_receipt(receipt: kamu_money_pg_artifact::CopyReceipt) {
    if receipt.evidence() == "unverified" {
        eprintln!("artifact: *** UNVERIFIED DEVELOPER COPY; not release evidence ***");
    }
    println!("copied\t{}\t{}\t{}", receipt.evidence(), receipt.version(), receipt.library_digest());
}
