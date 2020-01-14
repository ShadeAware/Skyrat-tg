/**
  * Movespeed modification datums.
  */

/datum/movespeed_modifier
	/// Whether or not this is a variable modifier. Variable modifiers can NOT be ever auto-cached. ONLY CHECKED VIA INITIAL(), EFFECTIVELY READ ONLY (and for very good reason)
	var/variable = FALSE

	/// Unique ID. You can never have different modifications with the same ID
	var/id

	/// Higher ones override lower priorities. This is NOT used for ID, ID must be unique, if it isn't unique the newer one overwrites automatically if overriding.
	var/priority = 0
	var/flags = NONE

	/// Multiplicative slowdown
	var/multiplicative_slowdown = 0

	/// Movetypes this applies to
	var/movetypes = ALL

	/// Movetypes this never applies to
	var/blacklisted_movetypes = NONE

	/// Other modification datums this conflicts with.
	var/conflicts_with

/*! How move speed for mobs works

Move speed is now calculated by using modifier datums which are added to mobs. Some of them (nonvariable ones) are globally cached, the variable ones are instanced and changed based on need.

This gives us the ability to have multiple sources of movespeed, reliabily keep them applied and remove them when they should be

THey can have unique sources and a bunch of extra fancy flags that control behaviour

Previously trying to update move speed was a shot in the dark that usually meant mobs got stuck going faster or slower

This list takes the following format

```Current movespeed modification list format:
		list(
			id = list(
				priority,
				flags,
				legacy slowdown/speedup amount,
				movetype_flags
			)
		)
```

WHen update movespeed is called, the list of items is iterated, according to flags priority and a bunch of conditions
this spits out a final calculated value which is used as a modifer to last_move + modifier for calculating when a mob
can next move

Key procs
* [add_movespeed_modifier](mob.html#proc/add_movespeed_modifier)
* [remove_movespeed_modifier](mob.html#proc/remove_movespeed_modifier)
* [has_movespeed_modifier](mob.html#proc/has_movespeed_modifier)
* [update_movespeed](mob.html#proc/update_movespeed)
*/

//ANY ADD/REMOVE DONE IN UPDATE_MOVESPEED MUST HAVE THE UPDATE ARGUMENT SET AS FALSE!

GLOBAL_LIST_EMPTY(movespeed_modification_cache)

/// Grabs a STATIC MODIFIER datum from cache. YOU MUST NEVER EDIT THESE DATUMS, OR IT WILL AFFECT ANYTHING ELSE USING IT TOO!
/proc/get_cached_movespeed_modifier(modtype)
	if(!ispath(modtype, /datum/movespeed_modifier))
		CRASH("[modtype] is not a movespeed modification typepath.")
	var/datum/movespeed_modifier/M = modtype
	if(initial(M.variable))
		CRASH("[modtype] is a variable modifier, and can never be cached.")
	return GLOB.movespeed_modification_cache[modtype] || (GLOB.movespeed_modification_cache[modtype] = new modtype)

///Add a move speed modifier to a mob. If a variable subtype is passed in as the first argument, it will make a new datum. If ID conflicts, it will overwrite the old ID.
/mob/proc/add_movespeed_modifier(datum/movespeed_modifier/type_or_datum, update = TRUE)
	if(ispath(type_or_datum))
		if(!initial(type_or_datum.variable))
			type_or_datum = get_cached_movespeed_modifier(type_or_datum)
		else
			type_or_datum = new type_or_datum
	var/oldpriority
	var/datum/movespeed_modifier/existing = LAZYACCESS(movespeed_modification, type_or_datum.id)
	if(existing)
		if(existing == type_or_datum)		//same thing don't need to touch
			return TRUE
		oldpriority = existing.priority
		remove_movespeed_modifier(existing, FALSE)
	LAZYSET(movespeed_modification, type_or_datum.id, type_or_datum)
	var/resort = type_or_datum.priority == oldpriority
	if(update)
		update_movespeed(resort)
	return TRUE

/// Remove a move speed modifier from a mob, whether static or variable.
/mob/proc/remove_movespeed_modifier(datum/movespeed_modifier/type_id_datum, update = TRUE)
	if(ispath(type_id_datum))
		ype_id_datum = initial(type_id_datum.id)
	else if(!istext(type_id_datum))		//if it isn't text it has to be a datum, as it isn't a type.
		type_id_datum = type_id_datum.id
	if(!LAZYACCESS(movespeed_modification, type_id_datum))
		return FALSE
	LAZYREMOVE(movespeed_modification, type_id_datum)
	if(update)
		update_movespeed(FALSE)
	return TRUE

/// Used for variable slowdowns like hunger/health loss/etc, works somewhat like the old list-based modification adds. Returns the modifier datum if successful
/mob/proc/add_or_update_variable_movespeed_modifier(datum/movespeed_modifier/type_id_datum, update = TRUE, multiplicative_slowdown)
	/*
	How this SHOULD work is:
	1. Ensures type_id_datum one way or another refers to a /variable datum. This makes sure it can't be cached. This includes if it's already in the modification list.
	2. Instantiate a new datum if type_id_datum isn't already instantiated + in the list, using the type. Obviously, wouldn't work for ID only.
	3. Add the datum if necessary using the regular add proc
	4. If any of the rest of the args are not null (see: multiplicative slowdown), modify the datum
	5. Update if necessary
	*/
	var/modified = FALSE
	var/inject = FALSE
	var/datum/movespeed_modifier/final
	if(istext(type_id_datum))
		final = LAZYACCESS(movespeed_modification, type_id_datum)
		if(!final)
			CRASH("Couldn't find existing modification when only provided an ID.")
	else if(ispath(type_id_datum))
		if(!initial(type_id_datum.variable))
			CRASH("Not a variable modifier")
		var/id = initial(type_id_datum.id)
		final = LAZYACCESS(movespeed_modification, id)
		if(!final)
			final = new type_id_datum
			inject = TRUE
			modified = TRUE
	else
		if(!initial(type_id_datum.variable))
			CRASH("Not a variable modifier")
		final = type_id_datum
		if(!LAZYACCESS(movespeed_modification, final.id))
			inject = TRUE
			modified = TRUE
	if(!isnull(multiplicative_slowdown))
		final.multiplicative_slowdown = multiplicative_slowdown
		modified = TRUE
	if(inject)
		add_movespeed_modifier(final, FALSE)
	if(update && modified)
		update_movespeed(TRUE)
	return final

///Handles the special case of editing the movement var
/mob/vv_edit_var(var_name, var_value)
	var/slowdown_edit = (var_name == NAMEOF(src, cached_multiplicative_slowdown))
	var/diff
	if(slowdown_edit && isnum(cached_multiplicative_slowdown) && isnum(var_value))
		remove_movespeed_modifier(/datum/movespeed_modifier/admin_varedit)
		diff = var_value - cached_multiplicative_slowdown
	. = ..()
	if(. && slowdown_edit && isnum(diff))
		add_or_update_variable_movespeed_modifier(/datum/movespeed_modifier/admin_varedit, multiplicative_slowdown = diff)

///Is there a movespeed modifier for this mob
/mob/proc/has_movespeed_modifier(datum/movespeed_modifier/datum_type_id)
	if(ispath(datum_type_id))
		datum_type_id = get_cached_movespeed_modifier(datum_type_id)
	else if(!istext(datum_type_id))
		datum_type_id = datum_type_id.id
	return LAZYACCESS(movespeed_modification, datum_type_id)

///Set or update the global movespeed config on a mob
/mob/proc/update_config_movespeed()
	add_or_update_variable_movespeed_modifier(/datum/movespeed_modifier/mob_config_speedmod, multiplicative_slowdown = get_config_multiplicative_speed())

///Get the global config movespeed of a mob by type
/mob/proc/get_config_multiplicative_speed()
	if(!islist(GLOB.mob_config_movespeed_type_lookup) || !GLOB.mob_config_movespeed_type_lookup[type])
		return 0
	else
		return GLOB.mob_config_movespeed_type_lookup[type]

///Go through the list of movespeed modifiers and calculate a final movespeed
/mob/proc/update_movespeed(resort = TRUE)
	if(resort)
		sort_movespeed_modlist()
	. = 0
	var/list/conflict_tracker = list()
	for(var/id in get_movespeed_modifiers())
		var/datum/movespeed_modifier/M = movespeed_modification[id]
		if(!(M.movetypes & movement_type)) // We don't affect any of these move types, skip
			continue
		if(M.blacklisted_movetypes & movement_type) // There's a movetype here that disables this modifier, skip
			continue
		var/conflict = M.conflicts_with
		var/amt = M.multiplicative_slowdown
		if(conflict)
			// Conflicting modifiers prioritize the larger slowdown or the larger speedup
			// We purposefuly don't handle mixing speedups and slowdowns on the same id
			if(abs(conflict_tracker[conflict]) < abs(amt))
				conflict_tracker[conflict] = amt
			else
				continue
		. += amt
	cached_multiplicative_slowdown = .

///Get the move speed modifiers list of the mob
/mob/proc/get_movespeed_modifiers()
	return movespeed_modification

///Calculate the total slowdown of all movespeed modifiers
/mob/proc/total_multiplicative_slowdown()
	. = 0
	for(var/id in get_movespeed_modifiers())
		var/datum/movespeed_modifier/M = movespeed_modification[id]
		. += M.multiplicative_slowdown

///Checks if a move speed modifier is valid and not missing any data
/proc/movespeed_data_null_check(datum/movespeed_modifier/M)		//Determines if a data list is not meaningful and should be discarded.
	. = TRUE
	if(M.multiplicative_slowdown)
		. = FALSE

/**
  * Sort the list of move speed modifiers
  *
  * Verifies it too. Sorts highest priority (first applied) to lowest priority (last applied)
  */
/mob/proc/sort_movespeed_modlist()
	if(!movespeed_modification)
		return
	var/list/assembled = list()
	for(var/our_id in movespeed_modification)
		var/datum/movespeed_modifier/M = movespeed_modification[our_id]
		if(movespeed_data_null_check(M))
			movespeed_modification -= our_id
			continue
		var/our_priority = M.priority
		var/resolved = FALSE
		for(var/their_id in assembled)
			var/datum/movespeed_modifier/other = assembled[their_id]
			if(other.priority < our_priority)
				assembled.Insert(assembled.Find(their_id), our_id)
				assembled[our_id] = M
				resolved = TRUE
				break
		if(!resolved)
			assembled[our_id] = M
	movespeed_modification = assembled
	UNSETEMPTY(movespeed_modification)
