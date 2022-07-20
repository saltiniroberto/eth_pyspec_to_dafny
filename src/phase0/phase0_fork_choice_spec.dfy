include "ssz.dfy"
include "simpletypes.dfy"
include "entities.dfy"
include "consts.dfy"

include "helpers.dfy"

import opened SSZ
import opened SimpleTypes
import opened Entities
import opened Consts

/*
    Return the epoch number at ``slot``.
    */
function method compute_epoch_at_slot(slot: Slot): Epoch
requires valid_constants()
{
  Epoch_new(slot / SLOTS_PER_EPOCH)
}

/*
    Return the start slot of ``epoch``.
    */
function method compute_start_slot_at_epoch(epoch: Epoch): Slot
{
  Slot_new(epoch * SLOTS_PER_EPOCH)
}

function method get_current_epoch(state: BeaconState): Epoch
function method is_slashable_attestation_data(data1: AttestationData, data2: AttestationData): bool
function method is_valid_indexed_attestation(state: BeaconState, attestation: IndexedAttestation): bool
function method get_indexed_attestation(state: BeaconState, attestation: Attestation): IndexedAttestation
function method get_active_validator_indices(state: BeaconState, epoch: Epoch): seq<ValidatorIndex>
function method get_total_active_balance(state: BeaconState): Gwei
function method process_slots_pure(state: BeaconState, slot: Slot): Outcome<BeaconState>
function method state_transition_pure(state: BeaconState, block: SignedBeaconBlock, check: bool): Outcome<BeaconState>

// functional pure
function get_slots_since_genesis_pure(store: Store_dt): int
requires valid_time_slots_pure(store) && valid_constants()
{
  (store.time - store.genesis_time) / SECONDS_PER_SLOT
}

// functional pure <==> functional impure
function get_current_slot_pure(store: Store_dt): Slot
requires valid_time_slots_pure(store) && valid_constants()
{
  Slot_new(GENESIS_SLOT + get_slots_since_genesis_pure(store))
}

function compute_slots_since_epoch_start_pure(slot: Slot): int
requires valid_constants()
{
    slot - compute_start_slot_at_epoch(compute_epoch_at_slot(slot))
}

function get_ancestor_pure(store: Store_dt, root: Root, slot: Slot): (ret: Outcome<Root>)
requires valid_blocks_pure(store.blocks)
decreases if root !in store.blocks then 0 else store.blocks[root].slot
{
  var block: BeaconBlock :- map_get(store.blocks, root);
  if block.slot > slot then
    get_ancestor_pure(store, block.parent_root, slot)
  else if block.slot == slot then
    Result(root)
  else
    Result(root)
}

function should_update_justified_checkpoint_pure(store: Store_dt, new_justified_checkpoint: Checkpoint): Outcome<bool>
requires valid_time_slots_pure(store) && valid_constants()
requires valid_blocks_pure(store.blocks)
{
  if compute_slots_since_epoch_start_pure(get_current_slot_pure(store)) < SAFE_SLOTS_TO_UPDATE_JUSTIFIED then
    Result(true)
  else
    var justified_slot: Slot := compute_start_slot_at_epoch(store.justified_checkpoint.epoch);
    var tmp_0 :- get_ancestor_pure(store, new_justified_checkpoint.root, justified_slot);
    if !(tmp_0 == store.justified_checkpoint.root) then
      Result(false)
    else
      Result(true)
}

function validate_target_epoch_against_current_time_pure(store: Store_dt, attestation: Attestation): Outcome<()>
requires valid_constants()
requires valid_time_slots_pure(store)
{
  var target: Checkpoint := attestation.data.target;
  var current_epoch: Epoch := compute_epoch_at_slot(get_current_slot_pure(store));
  var previous_epoch: Epoch := if (current_epoch > GENESIS_EPOCH) then current_epoch - 1 else GENESIS_EPOCH;
  var _ :- pyassert(target.epoch in [current_epoch, previous_epoch]);
  Result(())
}

function validate_on_attestation_pure(store: Store_dt, attestation: Attestation, is_from_block: bool): Outcome<()>
requires valid_constants()
requires valid_time_slots_pure(store)
requires valid_blocks_pure(store.blocks)
{
  var target: Checkpoint := attestation.data.target;
  if !is_from_block then
    validate_target_epoch_against_current_time_pure(store, attestation)
  else
    var _ :- pyassert(target.epoch == compute_epoch_at_slot(attestation.data.slot));
    var _ :- pyassert(target.root in store.blocks);
    var _ :- pyassert(attestation.data.beacon_block_root in store.blocks);
    var _ :- pyassert(store.blocks[attestation.data.beacon_block_root].slot <= attestation.data.slot);
    var target_slot: Slot := compute_start_slot_at_epoch(target.epoch);
    var tmp_0 :- get_ancestor_pure(store, attestation.data.beacon_block_root, target_slot);
    var _ :- pyassert(target.root == tmp_0);
    var _ :- pyassert(get_current_slot_pure(store) >= (attestation.data.slot + 1));
    Result(())
}

function store_target_checkpoint_state_pure(store: Store_dt, target: Checkpoint): Outcome<Store_dt>
{
  if target !in store.checkpoint_states then
    var tmp_0 :- map_get(store.block_states, target.root);
    var base_state: BeaconState := tmp_0.copy();
    var base_state :-
      if base_state.slot < compute_start_slot_at_epoch(target.epoch) then
        process_slots_pure(base_state, compute_start_slot_at_epoch(target.epoch))
      else
        Result(base_state);
    var store := store.(checkpoint_states := store.checkpoint_states[target := base_state]);
    Result(store)
  else
    Result(store)
}

function update_latest_messages_pure(store: Store_dt, attesting_indices: seq<ValidatorIndex>, attestation: Attestation): Store_dt
{
  var target: Checkpoint := attestation.data.target;
  var beacon_block_root: Root := attestation.data.beacon_block_root;
  var non_equivocating_attesting_indices: seq<ValidatorIndex> := seq_filter((i) => i !in store.equivocating_indices, attesting_indices);
  var loop_body := (store: Store_dt, i: ValidatorIndex) =>
    if i !in store.latest_messages || target.epoch > store.latest_messages[i].epoch then
      store.(latest_messages := store.latest_messages[i := LatestMessage(target.epoch, beacon_block_root)])
    else
      store;
  var store := seq_loop(non_equivocating_attesting_indices, store, loop_body);
  store
}

function on_tick_pure(store: Store_dt, time: uint64): Outcome<Store_dt>
requires time >= store.time
requires valid_constants()
requires valid_time_slots_pure(store)
requires valid_blocks_pure(store.blocks)
{
  var previous_slot: Slot := get_current_slot_pure(store);
  var store := store.(time := time);
  var current_slot: Slot := get_current_slot_pure(store);
  var store := if current_slot > previous_slot then
    var store := store.(proposer_boost_root := Root_new(0));
    store
  else
    store;
  if !(current_slot > previous_slot && compute_slots_since_epoch_start_pure(current_slot) == 0) then
    Result(store)
  else
    if store.best_justified_checkpoint.epoch > store.justified_checkpoint.epoch then
      var finalized_slot: Slot := compute_start_slot_at_epoch(store.finalized_checkpoint.epoch);
      var ancestor_at_finalized_slot: Root :- get_ancestor_pure(store, store.best_justified_checkpoint.root, finalized_slot);
      if ancestor_at_finalized_slot == store.finalized_checkpoint.root then
        var store := store.(justified_checkpoint := store.best_justified_checkpoint);
        Result(store)
      else
        Result(store)
    else
      Result(store)
} 

function on_block_pure(store: Store_dt, signed_block: SignedBeaconBlock): Outcome<Store_dt>
requires valid_constants()
requires valid_time_slots_pure(store)
requires valid_blocks_pure(store.blocks)
{
  var block: BeaconBlock := signed_block.message;
  var _ :- pyassert(block.parent_root in store.block_states);
  var tmp_0 :- map_get(store.block_states, block.parent_root);
  var pre_state: BeaconState := tmp_0.copy();
  var _ :- pyassert(get_current_slot_pure(store) >= block.slot);
  var finalized_slot: Slot := compute_start_slot_at_epoch(store.finalized_checkpoint.epoch);
  var _ :- pyassert(block.slot > finalized_slot);
  var tmp_1 :- get_ancestor_pure(store, block.parent_root, finalized_slot);
  var _ :- pyassert(tmp_1 == store.finalized_checkpoint.root);
  var state: BeaconState := pre_state.copy();
  var state :- state_transition_pure(state, signed_block, true);
  var store := store.(blocks := store.blocks[hash_tree_root(block) := block]);
  assume valid_blocks_pure(store.blocks);
  var store := store.(block_states := store.block_states[hash_tree_root(block) := state]);
  var time_into_slot: uint64 := (store.time - store.genesis_time) % SECONDS_PER_SLOT;
  var is_before_attesting_interval: bool := time_into_slot < (SECONDS_PER_SLOT / INTERVALS_PER_SLOT);
  var store :=
    if get_current_slot_pure(store) == block.slot && is_before_attesting_interval then
      store.(proposer_boost_root := Root_new(hash_tree_root(block)))
    else
      store;
  var store :-
    if state.current_justified_checkpoint.epoch > store.justified_checkpoint.epoch then
      var store :=
        if state.current_justified_checkpoint.epoch > store.best_justified_checkpoint.epoch then
          store.(best_justified_checkpoint := state.current_justified_checkpoint)
        else
          store;
      var tmp_2 :- should_update_justified_checkpoint_pure(store, state.current_justified_checkpoint);
      var store :=
        if tmp_2 then
          store.(justified_checkpoint := state.current_justified_checkpoint)
        else
          store;
      Result(store)
    else
      Result(store);
  var store :=
    if state.finalized_checkpoint.epoch > store.finalized_checkpoint.epoch then
      var store := store.(finalized_checkpoint := state.finalized_checkpoint);
      store.(justified_checkpoint := state.current_justified_checkpoint)
    else
      store;
  Result(store)
} 

function on_attestation_pure(store: Store_dt, attestation: Attestation, is_from_block: bool): Outcome<Store_dt>
requires valid_constants()
requires valid_time_slots_pure(store)
requires valid_blocks_pure(store.blocks)
{
  var _ :- validate_on_attestation_pure(store, attestation, is_from_block);
  var store :- store_target_checkpoint_state_pure(store, attestation.data.target);
  var target_state: BeaconState :- map_get(store.checkpoint_states, attestation.data.target);
  var indexed_attestation: IndexedAttestation := get_indexed_attestation(target_state, attestation);
  var _ :- pyassert(is_valid_indexed_attestation(target_state, indexed_attestation));
  var store := update_latest_messages_pure(store, indexed_attestation.attesting_indices, attestation);
  Result(store)
} 

function on_attester_slashing_pure(store: Store_dt, attester_slashing: AttesterSlashing): Outcome<Store_dt>
{
  var attestation_1: IndexedAttestation := attester_slashing.attestation_1;
  var attestation_2: IndexedAttestation := attester_slashing.attestation_2;
  var _ :- pyassert(is_slashable_attestation_data(attestation_1.data, attestation_2.data));
  var state: BeaconState :- map_get(store.block_states, store.justified_checkpoint.root);
  var _ :- pyassert(is_valid_indexed_attestation(state, attestation_1));
  var _ :- pyassert(is_valid_indexed_attestation(state, attestation_2));
  var indices: set<ValidatorIndex> := seq_to_set(attestation_1.attesting_indices) * seq_to_set(attestation_2.attesting_indices);
  var loop_body := (store: Store_dt, index: ValidatorIndex) =>
    store.(equivocating_indices := store.equivocating_indices + {index});
  var store := set_loop(indices, store, loop_body);
  Result(store)
}