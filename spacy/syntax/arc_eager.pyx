from __future__ import unicode_literals

from ._state cimport State
from ._state cimport has_head, get_idx, get_s0, get_n0
from ._state cimport is_final, at_eol, pop_stack, push_stack, add_dep
from ._state cimport head_in_buffer, children_in_buffer
from ._state cimport head_in_stack, children_in_stack

from ..structs cimport TokenC

DEF NON_MONOTONIC = True


cdef enum:
    SHIFT
    REDUCE
    LEFT
    RIGHT
    N_MOVES


cdef inline bint _can_shift(const State* s) nogil:
    return not at_eol(s)


cdef inline bint _can_right(const State* s) nogil:
    return s.stack_len >= 1 and not at_eol(s)


cdef inline bint _can_left(const State* s) nogil:
    if NON_MONOTONIC:
        return s.stack_len >= 1
    else:
        return s.stack_len >= 1 and not has_head(get_s0(s))


cdef inline bint _can_reduce(const State* s) nogil:
    if NON_MONOTONIC:
        return s.stack_len >= 2
    else:
        return s.stack_len >= 2 and has_head(get_s0(s))


cdef int _shift_cost(const State* s, const int* gold) except -1:
    assert not at_eol(s)
    cost = 0
    cost += head_in_stack(s, s.i, gold)
    cost += children_in_stack(s, s.i, gold)
    if NON_MONOTONIC:
        cost += gold[s.stack[0]] == s.i
    return cost


cdef int _right_cost(const State* s, const int* gold) except -1:
    assert s.stack_len >= 1
    cost = 0
    if gold[s.i] == s.stack[0]:
        return cost
    cost += head_in_buffer(s, s.i, gold)
    cost += children_in_stack(s, s.i, gold)
    cost += head_in_stack(s, s.i, gold)
    if NON_MONOTONIC:
        cost += gold[s.stack[0]] == s.i
    return cost


cdef int _left_cost(const State* s, const int* gold) except -1:
    assert s.stack_len >= 1
    cost = 0
    if gold[s.stack[0]] == s.i:
        return cost

    cost += head_in_buffer(s, s.stack[0], gold)
    cost += children_in_buffer(s, s.stack[0], gold)
    if NON_MONOTONIC and s.stack_len >= 2:
        cost += gold[s.stack[0]] == s.stack[-1]
    return cost


cdef int _reduce_cost(const State* s, const int* gold) except -1:
    cdef int cost = 0
    cost += children_in_buffer(s, s.stack[0], gold)
    if NON_MONOTONIC:
        cost += head_in_buffer(s, s.stack[0], gold)
    return cost


cdef class TransitionSystem:
    def __init__(self, list left_labels, list right_labels):
        self.mem = Pool()
        left_labels.sort()
        right_labels.sort()
        if 'ROOT' in right_labels:
            right_labels.pop(right_labels.index('ROOT'))
        if 'ROOT' in left_labels:
            left_labels.pop(left_labels.index('ROOT'))
        self.n_moves = 2 + len(left_labels) + len(right_labels) 
        moves = <Transition*>self.mem.alloc(self.n_moves, sizeof(Transition))
        cdef int i = 0
        moves[i].move = SHIFT
        moves[i].label = 0
        moves[i].clas = i
        i += 1
        moves[i].move = REDUCE
        moves[i].label = 0
        moves[i].clas = i
        i += 1
        self.label_ids = {'ROOT': 0}
        cdef int label_id
        for label_str in left_labels:
            label_str = unicode(label_str)
            label_id = self.label_ids.setdefault(label_str, len(self.label_ids))
            moves[i].move = LEFT
            moves[i].label = label_id
            moves[i].clas = i
            i += 1
        for label_str in right_labels:
            label_str = unicode(label_str)
            label_id = self.label_ids.setdefault(label_str, len(self.label_ids))
            moves[i].move = RIGHT
            moves[i].label = label_id
            moves[i].clas = i
            i += 1
        self._moves = moves

    cdef int transition(self, State *s, const Transition* t) except -1:
        if t.move == SHIFT:
            # Set the dep label, in case we need it after we reduce
            if NON_MONOTONIC:
                get_s0(s).dep = t.label
            push_stack(s)
        elif t.move == LEFT:
            add_dep(s, s.i, s.stack[0], t.label)
            pop_stack(s)
        elif t.move == RIGHT:
            add_dep(s, s.stack[0], s.i, t.label)
            push_stack(s)
        elif t.move == REDUCE:
            add_dep(s, s.stack[-1], s.stack[0], get_s0(s).dep)
            pop_stack(s)
        else:
            raise Exception(t.move)

    cdef Transition best_valid(self, const weight_t* scores, const State* s) except *:
        cdef bint[N_MOVES] valid
        valid[SHIFT] = _can_shift(s)
        valid[LEFT] = _can_left(s)
        valid[RIGHT] = _can_right(s)
        valid[REDUCE] = _can_reduce(s)

        cdef int best = -1
        cdef weight_t score = 0
        cdef weight_t best_r_score = -9000
        cdef int best_r_label = -1
        cdef int i
        for i in range(self.n_moves):
            if valid[self._moves[i].move] and (best == -1 or scores[i] > score):
                best = i
                score = scores[i]
            if self._moves[i].move == RIGHT and scores[i] > best_r_score:
                best_r_label = self._moves[i].label
        assert best >= 0
        cdef Transition t = self._moves[best]
        t.score = score
        if t.move == SHIFT:
            t.label = best_r_label
        return t

    cdef Transition best_gold(self, Transition* guess, const weight_t* scores,
                              const State* s,
                              const int* gold_heads, const int* gold_labels) except *:
        # If we can create a gold dependency, only one action can be correct
        cdef int[N_MOVES] unl_costs
        unl_costs[SHIFT] = _shift_cost(s, gold_heads) if _can_shift(s) else -1
        unl_costs[LEFT] = _left_cost(s, gold_heads) if _can_left(s) else -1
        unl_costs[RIGHT] = _right_cost(s, gold_heads) if _can_right(s) else -1
        unl_costs[REDUCE] = _reduce_cost(s, gold_heads) if _can_reduce(s) else -1

        guess.cost = unl_costs[guess.move]
        cdef Transition t
        cdef int target_label
        cdef int i
        if gold_heads[s.stack[0]] == s.i:
            target_label = gold_labels[s.stack[0]]
            if guess.move == LEFT:
                guess.cost += guess.label != target_label
            for i in range(self.n_moves):
                t = self._moves[i]
                if t.move == LEFT and t.label == target_label:
                    return t
        elif gold_heads[s.i] == s.stack[0]:
            target_label = gold_labels[s.i]
            if guess.move == RIGHT:
                guess.cost += guess.label != target_label
            for i in range(self.n_moves):
                t = self._moves[i]
                if t.move == RIGHT and t.label == target_label:
                    return t

        cdef int best = -1
        cdef weight_t score = -9000
        for i in range(self.n_moves):
            t = self._moves[i]
            if unl_costs[t.move] == 0 and (best == -1 or scores[i] > score):
                best = i
                score = scores[i]
        t = self._moves[best]
        t.score = score
        assert best >= 0
        return t
