# Case-suite coverage of the `#[pg_test]` contract

This manifest maps every `#[pg_test]` in `kamu-money-pg` to the portable SQL case that restates it.
`hygiene/tests/pg_cases.rs` recursively scans `kamu-money-pg/src/`, checks both directions of
the mapping, verifies every referenced SQL/golden pair, and requires a reason for each
`NOT-PORTABLE` row. Its test output derives the total, portable count, exception count, and source
locations from the current tree; none is a maintained constant.

## Why the port exists

`cargo pgrx test` manages its own PostgreSQL and cannot target YugabyteDB.
Restating the contract as `sql/` + `expected/` pairs makes the same cases run
against a single YB node, every node of a YB cluster, and the stock-PG15
reference.

## What is deliberately different from the Rust originals

- **Grouping.** In the backend a raised `ERROR` longjmps out of SPI and aborts the whole test
  transaction, so every refusal needed its own `#[pg_test]`. Under psql each statement is its own
  implicit transaction, so a refusal and the successes around it live in one file. Same
  assertions, fewer sessions.
- **`numeric` widths.** `the_size_tradeoff_against_numeric_is_measured_not_assumed` asserts the
  *relations* (the pinned type fixed at 16; numeric smaller for a typical amount, larger at the domain
  top), exactly as the Rust test does. The measured values 7 and 23 are not pinned, because
  `numeric`'s encoding is PostgreSQL's business and pinning it here would turn a change in someone
  else's type into a `kmoney` divergence.
- **Crafted `recv` payloads.** The Rust tests build malformed BINARY COPY
  fixtures inside the backend. `sql/09-wire.setup.sh` writes equivalent pinned
  fixtures on the server; `09-wire.sql` also checks live `kmoney_send` bytes.

If a test cannot be expressed here, its row must read
`NOT-PORTABLE: <reason>`. Silent omission fails the hygiene guard.

## The map

| # | `#[pg_test]` | Case | Assertion label in the golden |
|---|---|---|---|
| 1 | `a_cross_currency_expression_refusal_is_undefined_function` | `12-errors` | ERROR, `42883` |
| 2 | `a_forged_sum_state_refusal_is_invalid_binary_representation` | `12-errors` | ERROR, `22P03` |
| 3 | `a_mixed_column_cannot_be_ordered` | `05-mixed` | ERROR, operator `<` |
| 4 | `a_mixed_column_equality_is_currency_aware_and_never_raises` | `05-mixed` | `cross_currency_eq=false usd_ones=2` |
| 5 | `a_mixed_column_stores_several_currencies_side_by_side` | `05-mixed` | the three-currency render |
| 6 | `a_negative_amount_allocates_by_the_same_scheme` | `07-allocate` | `-0.06,-0.02,-0.02` and the inexact twin |
| 7 | `a_pinned_type_accepts_its_own_tag` | `02-text` | tagged in, bare out |
| 8 | `a_pinned_type_refuses_another_currencys_tag` | `02-text` | ERROR, expected USD got IDR |
| 9 | `a_pinned_type_renders_bare` | `02-text` | `10.50` |
| 10 | `a_pinned_value_hashes_as_the_erased_one_does` | `10-hash` | `pinned_hash=mixed_hash=true` |
| 11 | `a_pinned_value_is_sixteen_bytes` | `01-layout` | `pinned=16 erased=18` |
| 12 | `a_wrong_tag_refusal_is_invalid_text_representation` | `12-errors` | ERROR, `22P02` |
| 13 | `a_zero_parts_division_refusal_is_division_by_zero` | `12-errors` | ERROR, `22012` |
| 14 | `addition_is_exact_at_one_unit_of_the_eighteenth_decimal` | `03-arith` | `0.000000000000000003` |
| 15 | `addition_on_the_mixed_type_does_not_exist_either` | `05-mixed` | ERROR, operator `+` |
| 16 | `addition_past_the_domain_top_is_refused` | `03-arith` | ERROR, result outside the domain |
| 17 | `allocation_conserves_the_pinned_total` | `07-allocate` | `10.00` |
| 18 | `allocation_honours_weights_and_still_conserves` | `07-allocate` | `0.06,0.02,0.02` and the first-positive vector |
| 19 | `allocation_never_pays_a_zero_weight_recipient` | `07-allocate` | `0.02,0.00,0.01` |
| 20 | `allocation_refuses_a_null_weight` | `07-allocate` | ERROR, NULL weight |
| 21 | `allocation_refuses_weights_that_sum_to_zero` | `07-allocate` | ERROR, weights sum to zero |
| 22 | `an_invalid_weights_refusal_is_invalid_parameter_value` | `12-errors` | ERROR, `22023` |
| 23 | `an_out_of_domain_literal_refusal_is_numeric_value_out_of_range` | `12-errors` | ERROR, `22003` |
| 24 | `an_unknown_currency_is_refused_at_the_boundary` | `02-text` | ERROR, invalid money literal |
| 25 | `cross_currency_arithmetic_has_no_operator` | `03-arith` | ERROR, operator does not exist |
| 26 | `cross_currency_ordering_has_no_operator` | `11-compare` | ERROR, operator does not exist |
| 27 | `division_conserves_the_pinned_amount` | `06-div` | quotient, residue, and the rebuild |
| 28 | `division_refuses_an_unknown_rounding_mode` | `06-div` | ERROR, "bankers" |
| 29 | `every_iso_code_has_a_type` | `01-layout` | `pinned_type_count=178` |
| 30 | `every_pinned_type_has_its_own_sum` | `04-sum` | `sum_aggregates=178` |
| 31 | `kmoney_mixed_is_eighteen_bytes_with_no_header` | `01-layout` | `stored=18 in_memory=18` |
| 32 | `kmoney_refuses_what_numeric_silently_rounds` | `02-text` | ERROR, 19 fractional digits |
| 33 | `no_generated_type_carries_an_operator_class` | `01-layout` | `inspected=178 opclasses=0` |
| 34 | `numeric_silently_rounds_four_e_minus_nineteen_to_zero` | `01-layout` | `numeric_rounds_4e_minus_19_to_zero=true` |
| 35 | `one_unit_past_the_domain_is_refused` | `02-text` | ERROR, outside supported range |
| 36 | `pinned_arithmetic_stays_within_the_currency` | `03-arith` | `4.00` |
| 37 | `pinned_ordering_needs_no_currency_check` | `11-compare` | `ordered=true` |
| 38 | `pinned_recv_refuses_an_out_of_domain_binary_payload` | `09-wire` | ERROR, received amount outside the domain |
| 39 | `recv_refuses_a_binary_payload_whose_currency_is_unknown` | `09-wire` | ERROR, numeric code 0 |
| 40 | `recv_refuses_a_binary_payload_with_trailing_bytes` | `09-wire` | ERROR, incorrect binary data format |
| 41 | `recv_refuses_a_truncated_binary_payload` | `09-wire` | ERROR, insufficient data |
| 42 | `recv_refuses_an_out_of_domain_binary_payload` | `09-wire` | ERROR, received USD amount |
| 43 | `sum_of_no_rows_is_null` | `04-sum` | `empty_sum_is_null=true` |
| 44 | `sum_on_a_mixed_column_fails_at_plan_time` | `05-mixed` | ERROR, `sum(kmoney_mixed)` |
| 45 | `sum_totals_a_pinned_column` | `04-sum` | `10.00` |
| 46 | `the_binary_wire_round_trips_and_is_not_more_trusted_than_text` | `09-wire` | `all_recv=true`, `widths=16/18` and the round trip |
| 47 | `the_catalog_says_fixed_length_plain_and_byte_aligned` | `01-layout` | `kmoney_mixed=18/f/c/p,kmoney_usd=16/f/c/p` |
| 48 | `the_conversion_out_of_mixed_proves_the_currency` | `05-mixed` | `2.50` |
| 49 | `the_conversion_out_of_mixed_refuses_corrupt_units` | NOT-PORTABLE: SQL text and binary receive reject out-of-domain units before they can become a `kmoney_mixed`; this defense-in-depth test constructs the otherwise unreachable corrupt Rust value directly. | — |
| 50 | `the_conversion_out_of_mixed_refuses_the_wrong_currency` | `05-mixed` | ERROR, expected USD got IDR |
| 51 | `the_division_identity_holds_for_every_rounding_mode` | `06-div` | seven `<mode>=true` lines |
| 52 | `the_domain_top_round_trips` | `02-text` | `999999999999999999.999999999999999999` |
| 53 | `the_native_type_and_the_text_storage_agree` | `02-text` | `render_disagreements=0` / `reparse_mismatches=0` |
| 54 | `the_persisted_hash_values_are_pinned_not_merely_consistent` | `10-hash` | the four pinned `int4` values |
| 55 | `the_pinned_binary_wire_round_trips` | `09-wire` | `pinned_roundtrip_exact=true rows=2` |
| 56 | `the_residue_is_negative_under_round_up_modes` | `06-div` | `3.333333333333333334` with residue `-0.000000000000000002` |
| 57 | `the_size_does_not_depend_on_the_value` | `01-layout` | `distinct_sizes=1` |
| 58 | `the_size_tradeoff_against_numeric_is_measured_not_assumed` | `01-layout` | `kmoney_usd_fixed_at_16=` |
| 59 | `the_sum_aggregate_combines_an_empty_partial` | `04-sum` | `empty_partial_is_identity=true` |
| 60 | `the_sum_aggregate_is_plan_independent_across_a_domain_edge_transient` | `04-sum` | two orders, one total |
| 61 | `the_sum_aggregate_rejects_a_forged_transition_state` | `04-sum` | ERROR, state must be 32 bytes |
| 62 | `the_sum_aggregate_rejects_a_total_that_leaves_the_domain` | `04-sum` | ERROR, sum overflow |
| 63 | `the_sum_aggregate_reports_a_total_too_wide_for_i128` | `04-sum` | ERROR naming the exact 171-term total |
| 64 | `the_text_form_matches_money_core` | `02-text` | the five-form line |
| 65 | `there_is_no_cast_to_numeric` | `11-compare` | ERROR, cannot cast to numeric |

## Running it

```sh
just test-yb-regress     # builds the extension, then runs it on a live single-node YugabyteDB
just test-yb-cluster     # every node of a 3-node RF=3 cluster
```

Or by hand, against anything that speaks the protocol and has `kmoney` installed:

```sh
kamu-money-pg/tests/pg_regress/run-suite.sh \
    --client "psql -h 127.0.0.1 -p 5432 -U postgres" --label local
```
