# Command mappings: explicit inter-interface specifications

`cli/` has two specification languages. `define-command-interface`
(`dsl.rkt` over `spec.rkt`) declares what one command's CLI looks like —
every switch, flag, option, and operand named by a *keyword id* with its
concrete spellings, value behavior, and arities — and drives
parse/edit/render of invocations. `define-command-mapping`
(`mapping-dsl.rkt` over `mapping.rkt`) is an explicit DSL that depends on
the per-command interface specifications for two commands: a mapping
module names the two interface values (`#:from grep-cli`, `#:to rg-cli`)
and its clauses relate source keywords to target keywords, validated at
definition time against both interfaces. Concrete spellings never appear
in a mapping; rendering picks the target alias from the target interface
spec. Mappings are never generated — the language exists precisely so a
person writes and owns every inter-interface assertion, clause by clause.

A mapping is one-directional and partial: its domain is the fragment of
the source command the author can translate faithfully, and everything
outside the domain rejects, so the intercepted command runs unmodified.
The grep→rg instance lives in `mappings/grep-rg.rkt`, and
`transformers/grep.rkt` is only the plumbing around it.

## Formal model

### Definitions

Fix an interface `S` (a `command-interface` value) without subcommands.
Write `Flags(S)` for its flag ids, `Opts(S)` for its option ids,
`names(S)` for its head names, and `Slots(S)` for its operand slots in
declared order; each slot `s` carries an arity
`ar(s) ∈ {one, optional, many}` and a guard `γ_s` (the predicate from its
`#:when`/`#:unless` clause; the constantly-true predicate if absent). `V`
is the set of strings. For a set `X`, `Mult(X)` is the set of finite
multisets over `X`: functions `X → ℕ` with finite support; `|m|` is total
multiplicity, `a ∈ m` means `m(a) ≥ 1`, and `⊎` is pointwise sum.

**Definition (argument alphabet).**
`Arg(S) = Flags(S) ⊎ { (o, v) : o ∈ Opts(S), v ∈ V_o }`, where
`V_o = V ∪ {⊥}` if `o` is `#:optional-value` and `V_o = V` otherwise
(`⊥` marks an omitted optional value). Write `id(a)` for the flag or
option id of `a ∈ Arg(S)`.

**Definition (abstract invocations).** `AbsInv(S)` is the set of triples
`(h, m, u)` with `h ∈ names(S)`, `m ∈ Mult(Arg(S))`, and
`u : Slots(S) → V*` (finite sequences of values), satisfying the
well-formedness conditions the interface declares:

1. *(repeatability)* for every option `o` not marked `#:repeatable`,
   `Σ_{v ∈ V_o} m((o, v)) ≤ 1`;
2. *(operand arity and guards)* for every slot `s`: if `γ_s(h, m)` is
   false then `u(s)` is empty; if `γ_s(h, m)` is true then `|u(s)| = 1`
   when `ar(s) = one`, `|u(s)| ≤ 1` when `ar(s) = optional`, and `|u(s)|`
   is unconstrained when `ar(s) = many`.

Condition 1 bounds options only; flags may carry any multiplicity
(`grep -i -i` parses, renders, and round-trips with
`m(ignore-case) = 2`), and every construction below preserves
multiplicity. Guards in the implementation are evaluated in a second
parsing pass, against the completely classified invocation — operand
slots are assigned only after every dash argument is known — so `γ_s` is
well-typed over `(h, m)` even when options follow operands.
Conditions 1–2 delimit exactly the parse-realizable triples;
Proposition 1's surjectivity depends on this. For an interface with
subcommands, `AbsInv(S)` is the disjoint sum, over subcommands `sc`, of
pairs of an outer dash-argument multiset and an abstract invocation of
`sc`'s interface; every result below passes through this sum
componentwise, so proofs are stated for the subcommand-free case.

With `AbsInv(S)` fixed, write:

- `T` — the set of finite sequences of shell words (the token sequences the
  safe reader produces for one pipeline stage).
- `W_S ⊆ T` — the sequences `parse_S` accepts (does not reject).
- `Inv(S)` — parse results: invocations carrying surface data (source
  words) per argument, as built by `parse.rkt`.
- `α_S : Inv(S) → AbsInv(S)` — surface erasure: forget each argument's
  surface words and the relative order of the dash region, keeping the
  head name, the multiset of arguments as elements of `Arg(S)`, and the
  operand assignment. That `α_S` lands in `AbsInv(S)` — parse results
  satisfy conditions 1–2 — is an invariant of `parse.rkt`, which enforces
  repeatability and slot arity/guards while parsing.
- `π_S = α_S ∘ parse_S : W_S → AbsInv(S)`.
- `r_S : AbsInv(S) → T` — canonical rendering: each argument emitted with
  its canonical alias (`arg-spec-render-alias`: first long, else first
  short, else first literal; long option values `=`-attached), operand
  values in slot order. This is `render-invocation` restricted to
  surface-free invocations.

**Invariant (RT), an obligation on the library, per interface:** for
every `a ∈ AbsInv(S)`, `r_S(a) ∈ W_S` and `π_S(r_S(a)) = a` — a
canonically rendered well-formed abstract invocation parses, and parses
back to itself. This is the precise content of the library's
verbatim-fidelity / canonical-rendering contract (`invocation.rkt`,
`parse.rkt`); every result below that uses `r_S` is conditional on RT for
the interface involved.

### Lemmas

**Lemma 1 (kernels are equivalences).** For any function `g : X → Y`,
`ker g = { (x₁, x₂) : g(x₁) = g(x₂) }` is an equivalence relation on `X`.
*Proof.* Reflexivity, symmetry, transitivity of `=` on `Y` pull back along
`g`: `g(x)=g(x)`; `g(x₁)=g(x₂) ⇒ g(x₂)=g(x₁)`;
`g(x₁)=g(x₂) ∧ g(x₂)=g(x₃) ⇒ g(x₁)=g(x₃)`. ∎

**Lemma 2 (a left inverse forces injectivity).** If `g : X → Y` and
`g' : Y → X` satisfy `g' ∘ g = id_X`, then `g` is injective.
*Proof.* `g(x₁) = g(x₂) ⇒ x₁ = g'(g(x₁)) = g'(g(x₂)) = x₂`. ∎

**Lemma 3 (pivot lifting).** Let `f : A ⇀ Mult(B)` assign to each
argument a finite multiset of images, and let `p : dom(f) → B` (the
*pivot*) satisfy: (a) `f(a)(p(a)) = 1` for every `a ∈ dom(f)`;
(b) `p(a) ∉ supp(f(a′))` for all `a′ ∈ dom(f)` with `a′ ≠ a`. Then
`f̂ : Mult(dom f) → Mult(B)` defined by
`f̂(m) = ⊎_{a ∈ dom f} m(a) · f(a)` is injective, with each
multiplicity recovered as `m(a) = f̂(m)(p(a))`; and `f̂(m)` is finitely
supported because `m` is and each `f(a)` is.
*Proof.* For any `a ∈ dom(f)`:
`f̂(m)(p(a)) = Σ_{a′ ∈ dom f} m(a′) · f(a′)(p(a)) = m(a) · f(a)(p(a)) =
m(a)`, where (b) zeroes every term with `a′ ≠ a` and (a) gives the
coefficient 1. Hence `f̂(m₁) = f̂(m₂)` forces `m₁(a) = m₂(a)` for every
`a ∈ dom(f)`; both are supported on `dom(f)`, so `m₁ = m₂`. ∎
The elementwise case is the specialization to singleton images: if
`f₀ : A ⇀ B` is injective, take `f(a) = {f₀(a)}` and `p = f₀` — (a) is
immediate and (b) is exactly injectivity of `f₀` — and `f̂` is the usual
multiplicity-preserving relabeling. Condition (b) also forces `p` to be
injective: `p(a) = p(a′)` with `a ≠ a′` would put `p(a)` in
`supp(f(a′))`, since `p(a′) ∈ supp(f(a′))` by (a).

### Propositions

**Proposition 1 (the parser presents `AbsInv(S)` as a quotient set).**
"Quotient" means the quotient of a set by an equivalence relation — the
set of equivalence classes, together with the canonical projection
`x ↦ [x]`. Assume RT for `S`. Then: (i) `π_S` is surjective;
(ii) `W_S / ker π_S → AbsInv(S)`, `[w] ↦ π_S(w)`, is a well-defined
bijection, so `π_S` factors as the canonical projection
`W_S → W_S / ker π_S` followed by that bijection; (iii) `r_S` is
injective.
*Proof.* (i) For any `a ∈ AbsInv(S)`, `a = π_S(r_S(a))` by RT.
(ii) Well-defined and injective: `[w₁] = [w₂] ⟺ π_S(w₁) = π_S(w₂)` is the
definition of `ker π_S` (an equivalence by Lemma 1); surjective by (i).
The factorization is then immediate: `w ↦ [w] ↦ π_S(w)`.
(iii) `π_S` is a left inverse of `r_S` by RT; apply Lemma 2. ∎

*Interpretation.* The domain a mapping works on, `AbsInv(S)`, is — up to
the bijection in (ii) — the set of `ker π_S`-classes of accepted token
sequences. `ker π_S` contains alias choice (`-r` vs `--recursive`),
short-cluster grouping (`-in` vs `-i -n`), `=`-attachment, and
permutations of the dash region — each leaves `α_S ∘ parse_S` fixed — so
a mapping defined on `AbsInv(S)` treats all of these alike, and by (i)
reaches everything expressible: every abstract invocation is realized by
some token sequence.

**Proposition 2 (canonicalization).** Let the `identify` clauses define
partial functions `ρ₁, …, ρ_n : AbsInv(S) ⇀ AbsInv(S)`, each given by:
match the left pattern, replace by the right — with the domain of `ρ_i`
restricted to inputs whose rewrite result satisfies well-formedness
conditions 1–2 (this restriction is necessary: rewriting `colour` to
`color` in an invocation already containing `color` would give a
non-repeatable option multiplicity 2, and a rewrite can flip an operand
guard). Require, as static checks: (a) each `ρ_i` strictly decreases the
measure
`μ(h, m, u) = (headrank(h), |m|, Σ_{a∈m} m(a)·idrank(a), Σ_{a∈m} m(a)·vrank(a))`
in lexicographic order on ℕ⁴, where `headrank : names(S) → ℕ` is an
injection given by position in declared order, `idrank : Arg(S) → ℕ`
factors through `id(a)` and is injective on ids (position in declared
order), and `vrank(a) = 1` if `a = (o, ⊥)` and `0` otherwise;
(b) rewriting is deterministic — apply the lowest-index applicable rule,
repeat. Then every `a ∈ AbsInv(S)` reaches a unique normal form `nf(a)`
in finitely many steps. Define `C = nf(AbsInv(S))` and `≡_R = ker nf`.
Then `≡_R` is an equivalence relation, `nf(a) = nf(b) ⟺ a ≡_R b`, and
`nf` restricted to `C` is the identity (so `nf ∘ nf = nf`).
*Proof.* Termination: lexicographic order on ℕ⁴ is well-founded, and each
step strictly decreases `μ`, so no infinite rewrite sequence exists.
Uniqueness: the strategy in (b) is a function (at each state the applied
rule — or halting — is determined, and each rule application, being a
multiset operation, does not depend on a choice of occurrence), so `nf`
is a function `AbsInv(S) → AbsInv(S)`. `≡_R` is an equivalence by
Lemma 1. `nf|_C = id`: `nf(a)` is by construction a state where no rule
applies, so running the strategy on it halts immediately; idempotence
follows. ∎
Because the `ρ_i` are partial, a normal form may still contain an
identified-away argument whose rewrite could not legally fire (e.g.
`grep --color=x --colour=y`); such an argument is unclaimed by any
mapping clause, so the invocation flows to the reject path.

**Proposition 3 (clause soundness).** Suppose the static checks pass:
1. *(disjoint domains)* each mapping clause `k` denotes a partial
   function `f_k : A_k ⇀ Mult(Arg(T))` with `A_k ⊆ Arg(S)`, and the
   `A_k` are pairwise disjoint (each source id claimed by at most one
   clause);
2. *(clause denotations and pivots)* every image `f_k(a)` is a nonempty
   multiset in which each target id occurs at most once, and each clause
   designates a *pivot target id* `t_k`:
   `same`/`rename` clauses give singleton images
   `a ↦ { a[id := id′] }` carrying values unchanged, with pivot `id′`
   (a `same` clause listing several ids denotes one such unary clause
   per id);
   a `value from to #:forward g #:witness g′` clause gives
   `(o, v) ↦ { (o′, g(v)) }` with pivot `o′`, and `g′ ∘ g = id`
   certifies injectivity of `g` by Lemma 2;
   a `split from (to₁ … toₙ)` clause distributes one source argument
   across `n` target arguments,
   `a ↦ { to₁-argument, …, toₙ-argument }`, each `toᵢ` carrying the
   source value through its own forward function `gᵢ` (the identity if
   omitted), with pivot `to₁`, whose forward carries the mandatory
   witness obligation (`g₁′ ∘ g₁ = id`, Lemma 2);
3. *(disjoint emissions)* the sets of target ids emitted by distinct
   clauses are disjoint, and the target ids introduced by `add` clauses
   are emitted by no clause;
4. *(heads and operands)* the head map `φ` is injective on the head
   names occurring in `C`, and the operand alignment `χ` is a slot
   renaming carrying value sequences unchanged — a bijection between
   slot assignments.

Let `f = ⋃_k f_k` (well-defined by check 1) and let
`p(a) = ` the pivot argument of `a`'s clause — for `same`/`rename` the
relabeled argument itself, for `value`/`split` the argument
`(t_k, g₁(v))`. Then `p` satisfies Lemma 3's hypotheses: (a) each image
contains its pivot argument exactly once (check 2: the pivot id occurs
at most once per image, and `f_k(a)` contains one argument with that
id); (b) for `a′ ≠ a` in the same clause, `supp(f_k(a′))`'s only
argument with id `t_k` is `p(a′) ≠ p(a)` (injectivity of the pivot
forward, Lemma 2), and for `a′` in a different clause, `t_k` is not
emitted at all (check 3). So `f̂(m) = ⊎_a m(a)·f(a)` is injective on
`Mult(dom f)` by Lemma 3, and multiplicity is preserved through the
pivot: `grep -i -i` maps to `rg -i -i`.

Define
`dom(M₀) = { (h, m, u) ∈ C : supp(m) ⊆ dom(f),` every mapping-rule
guard accepts `(h, m, u)`, and the image below satisfies `T`'s
well-formedness conditions 1–2 `}` — `add`-clause guards are *not*
domain conditions: an unsatisfied `#:when` simply contributes nothing
to `adds` — and for `(h, m, u) ∈ dom(M₀)`
`M₀(h, m, u) = (φ(h), f̂(m) ⊎ adds(h, m, u), χ(u))`,
where `adds(h, m, u) ∈ Mult(Arg(T))` is the multiset of constant
arguments contributed by the `add` clauses whose guards accept
`(h, m, u)`. Then `M₀ : dom(M₀) → AbsInv(T)` is injective.
*Proof.* Suppose `M₀(h₁, m₁, u₁) = M₀(h₂, m₂, u₂)`. Heads:
`φ(h₁) = φ(h₂)` and `φ` is injective (check 4), so `h₁ = h₂`.
Arguments: `add`-introduced arguments occupy target ids emitted by no
clause (check 3), so restricting the equal middle components to
arguments whose id is emitted by some clause gives `f̂(m₁) = f̂(m₂)` —
the `adds` contributions are excluded by the id restriction, and both
`m_i` are supported on `dom f` — whence `m₁ = m₂` by Lemma 3; `adds` is
a function of the input, which is now determined. Operands:
`χ(u₁) = χ(u₂)` and `χ` is a bijection, so `u₁ = u₂`. ∎
Restricting `dom(M₀)` (coverage, guards, target well-formedness) shrinks
the domain of an injective function, which stays injective; at runtime
each restriction is a reject.

**Proposition 4 (injectivity up to declared equivalences).** Let
`M = M₀ ∘ nf : AbsInv(S) ⇀ AbsInv(T)` with `M₀` injective (Prop. 3). For
all `a, b` in `dom(M) = nf⁻¹(dom(M₀))`: `M(a) = M(b) ⇒ a ≡_R b`;
equivalently, `M` induces an injection `dom(M)/≡_R ⇀ AbsInv(T)`.
*Proof.* `M₀(nf(a)) = M₀(nf(b)) ⇒ nf(a) = nf(b)` (injectivity of `M₀`)
`⇒ a ≡_R b` (Prop. 2). ∎

**Proposition 5 (composition).** If `f : A ⇀ B` and `g : B ⇀ C` are
partial injections, so is `g ∘ f`, on `dom(f) ∩ f⁻¹(dom(g))`.
*Proof.* `g(f(a)) = g(f(b)) ⇒ f(a) = f(b) ⇒ a = b`, applying injectivity
of `g` then `f`. ∎

**Proposition 6 (constructibility).** Every object above is computable,
and every quotient is used only through a computable presentation:
(i) `T`, `W_S`, `Inv(S)`, and `AbsInv(S)` are sets of finite syntactic
objects — finite sequences of strings, finitely supported multisets over
an alphabet of ids and id–string pairs, finite maps — so equality on each
is decidable, and well-formedness (conditions 1–2) is decidable per
triple (finitely many slots and guard evaluations).
(ii) `parse_S`, `α_S`, `r_S`, each `ρ_i`, `nf`, each `f_k`, `φ`, `χ`,
`adds`, `M₀`, and `M` are computable: each is structural recursion or
finite case analysis over these finite objects, and `nf` terminates by
Proposition 2. The Racket implementation of each is its computability
witness.
(iii) `ker π_S` is decidable on `W_S` — compute `π_S` on both sides and
compare — and the quotient `W_S / ker π_S` is never constructed as data:
Proposition 1(ii) is a statement *about* the function `π_S`, and every
downstream use of it consists of applying `π_S` to concrete token
sequences.
(iv) `≡_R` is decidable — compute `nf` on both sides and compare — and
its quotient is presented by `nf` itself: `nf` is a computable
idempotent (Prop. 2), `C = im(nf)` is its set of canonical
representatives, membership in `C` is decidable (`nf(a) = a`), and
Proposition 4 is used only as the implication
`M(a) = M(b) ⇒ nf(a) = nf(b)` between computable values.
Hence each equivalence here is a decidable relation given as the kernel
of a computable function, and each quotient is represented by a
computable canonical-form function; the implementation manipulates
representatives only.
*Proof.* (i) is structural. (ii) is by construction, with termination of
`nf` from Proposition 2. (iii) and (iv) are compositions of computable
functions followed by a decidable equality test; idempotence of `nf` and
`nf|_C = id` are Proposition 2. ∎

**Corollary (end-to-end faithfulness).** Let `t′ : W_S ⇀ T` be the
implemented transformer: parse, canonicalize and apply clauses via
`invocation.rkt` edits, render surface-faithfully (untouched arguments
keep their original spellings). Assume the render-faithfulness
invariant **(RF)**: for every `w ∈ dom(t′)`,
`t′(w) ∈ W_T` and `π_T(t′(w)) = M(π_S(w))` — the renderer emits a token
sequence that parses back to the abstract invocation the mapping
produced. (RF is the same kind of obligation on `render-invocation` as
RT, extended to edited invocations; RT enters only here, as the reason
the canonical composite `r_T ∘ M ∘ π_S` satisfies RF. `mapping-forward`
enforces the `t′(w) ∈ W_T` half of RF mechanically, by re-parsing its
rendered result against the target interface and rejecting on
failure.) Then: if `t′(w₁) = t′(w₂)` then
`nf(π_S(w₁)) = nf(π_S(w₂))` — two source command lines receive the same
rewrite only if their abstract invocations are `≡_R`-equivalent.
*Proof.* Apply `π_T` to `t′(w₁) = t′(w₂)`: by RF,
`M(π_S(w₁)) = M(π_S(w₂))`. By Prop. 4, `π_S(w₁) ≡_R π_S(w₂)`, and by
Prop. 2 this is `nf(π_S(w₁)) = nf(π_S(w₂))`. ∎

This corollary is the purpose of the language: the rewrite collapses two
commands only when they were declared equivalent, so the emitted command
is faithful evidence of what was asked. The fuzz harness
(`tests/fuzz/`, `nix run .#fuzz-test`) checks the *semantic* truth of
the declared `≡_R` generators and rules — the part no static check can
reach — by extensional equivalence against real GNU grep and rg.

## Design notes

- **Erasure is an `identify`.** An `identify` clause is an owned semantic
  assertion — `fgrep ≡ grep -F`, bare `--color ≡ --color=auto` — and it
  acts by quotienting the mapping's domain (Prop. 2), leaving the
  injectivity of `M₀` untouched (Prop. 3). Relabelings are `rename`.
- **Distribution is a `split`, and its injectivity rides the pivot.**
  One source argument may map to several target arguments, but
  elementwise injectivity of each clause is not enough once images are
  multisets — if one source argument's image were `{b}` and another's
  `{b, b}`, two copies of the first would collide with one of the
  second. Lemma 3's pivot conditions exclude exactly this: the pivot
  target occurs once in its own image and nowhere else, so source
  multiplicity and value are read back off the pivot column.
- **Canonicalization is partial, and stuck means reject.** `identify`
  rewrites apply only when their result is well-formed, so a pathological
  source (`grep --color=x --colour=y`) normalizes to a form still
  containing `colour`, which no clause claims, and the stage rejects —
  the same reject-never-corrupt discipline as the parser.
- **Partiality carries the hard cases.** A mapping's domain can be as
  narrow as the author can defend; every proposition above is stated for
  partial maps, so a future narrow-domain
  `find DIR -name GLOB` ↦ `rg --files -g GLOB DIR` mapping is
  well-formed over exactly that fragment.

## The grep → rg instance

`mappings/grep-rg.rkt`:

```racket
(define-command-mapping grep->rg
  #:from grep-cli
  #:to   rg-cli
  #:heads (("grep" . "rg"))
  #:domain in-domain?

  (identify (head "fgrep") (head "grep" (flag fixed-strings)))
  (identify (head "egrep") (head "grep" (flag extended-regexp)))
  (identify (option colour) (option color))
  (identify (option color #f) (option color "auto"))
  (identify (flag extended-regexp) ε)   ; rg's default grammar is extended

  (same line-number ignore-case invert word-regexp line-regexp
        files-with-matches only-matching quiet with-filename fixed-strings
        text byte-offset pattern pattern-file color
        after-context before-context context max-count
        no-filename no-messages)
  (split count (count include-zero))    ; grep -c prints zero counts
  (split recursive (hidden no-ignore))  ; grep -r filters nothing
  (rename perl-regexp pcre2)
  (rename include glob)
  (operands (pattern-operand . pattern-operand)
            (files . paths))
  #:unmapped reject)
```

The domain predicate (`in-domain?`, defined before the mapping form —
`#:domain` is evaluated at definition time) is the conjunction of
fuzz-derived semantic side conditions, each commented with the
divergence it excludes:

- regex dialect: plain grep is BRE while rg's default is ERE-like, so
  bare-grep patterns must lie in the BRE/ERE-neutral fragment (no
  `+ ? | ( ) { } \`, no leading `*`); with `-E`, no braces or escapes;
  `-F` unrestricted; `-P` (PCRE2 both sides) admits exactly one pattern
  and no `-f` (GNU grep's `-P` is single-pattern); `-f` is claimed only
  under `-F`; mixed dialect selectors rejected;
- at most one of `count`/`files-with-matches`/`only-matching` (grep
  fixed precedence vs rg last-wins);
- at most one of `word-regexp`/`line-regexp` (grep gives `-x`
  precedence; rg matches with `-w` regardless);
- `only-matching` excludes `invert` and the context options, and
  requires non-empty, non-nullable visible patterns (grep skips empty
  matches and ignores context under `-o`; rg does neither);
- `invert` requires non-empty patterns (GNU grep short-circuits `-v`
  with a universal pattern);
- `files-without-match` is not claimed: GNU grep's exit status under
  `-L` reflects match-found, rg's reflects file-listed — extensionally
  irreconcilable;
- `recursive-follow` (`-R`) is not claimed: it would have to emit
  `follow` plus `hidden`/`no-ignore`, overlapping the `recursive`
  clause's emissions, which check 3 forbids.

One divergence is documented rather than guarded, because operand
*types* are invisible to invocation-level predicates: `grep pat dir`
without `-r` errors (exit 2) where `rg pat dir` recurses — no clause or
domain condition can distinguish a file operand from a directory operand
at transform time.

## Static checks and runtime

Definition-time checks are the hypotheses of Props. 2–3, plus
well-formedness: every `from` id declared by the source interface and
every `to` id by the target; kinds match (flag↔flag, option↔option);
target-id emissions pairwise disjoint; a `#:repeatable` source option
maps only to `#:repeatable` target options; an `#:optional-value` source
option maps to a required-value target option only if an `identify`
with left pattern `(o, ⊥)` eliminates `⊥` first; each source id claimed
once; identify patterns disjoint and `μ`-decreasing; heads and operand
slots aligned injectively; coverage accounting (unclaimed source ids
form the reject set). Value compatibility for enumerated options
(`#:values` in the interface specs) is derived from the two specs
rather than restated in the mapping: a value outside the source
enumeration rejects at the source parse, and a source-valid value
outside the target enumeration rejects at the target re-parse.
Witness laws are validated on the mapping's
literal values at construction time and re-checked per translated value
at runtime (an unfaithful forward/witness pair rejects the stage rather
than producing a non-injective translation). Clause guards, the domain
predicate, and target-side well-formedness — the latter as a full
re-parse of the rendered result against the target interface — are
evaluated per invocation at runtime, rejecting on failure. Each such
check is a decidable test on finite data (Prop. 6).

## Modules

| module | provides |
|---|---|
| `mapping.rkt` | `make-command-mapping` (constructor validation: the Prop. 2–3 hypotheses incl. `μ`-decrease and witness checks), `mapping-forward` (domain → canonicalize → coverage/guards → apply clauses → set head → target re-parse), `mapping->transformer` |
| `mapping-dsl.rkt` | `define-command-mapping` |
| `mappings/grep-rg.rkt` | `grep->rg` |
