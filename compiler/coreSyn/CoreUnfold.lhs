%
% (c) The University of Glasgow 2006
% (c) The AQUA Project, Glasgow University, 1994-1998
%

Core-syntax unfoldings

Unfoldings (which can travel across module boundaries) are in Core
syntax (namely @CoreExpr@s).

The type @Unfolding@ sits ``above'' simply-Core-expressions
unfoldings, capturing ``higher-level'' things we know about a binding,
usually things that the simplifier found out (e.g., ``it's a
literal'').  In the corner of a @CoreUnfolding@ unfolding, you will
find, unsurprisingly, a Core expression.

\begin{code}
module CoreUnfold (
	Unfolding, UnfoldingGuidance,	-- Abstract types

	noUnfolding, mkImplicitUnfolding, 
        mkUnfolding, mkCoreUnfolding,
	mkTopUnfolding, mkSimpleUnfolding,
	mkInlineUnfolding, mkInlinableUnfolding, mkWwInlineRule,
	mkCompulsoryUnfolding, mkDFunUnfolding,

	interestingArg, ArgSummary(..),

	couldBeSmallEnoughToInline, inlineBoringOk,
	certainlyWillInline, smallEnoughToInline,

	callSiteInline, CallCtxt(..), 

	exprIsConApp_maybe

    ) where

#include "HsVersions.h"

import StaticFlags
import DynFlags
import CoreSyn
import PprCore		()	-- Instances
import TcType           ( tcSplitDFunTy )
import OccurAnal        ( occurAnalyseExpr )
import CoreSubst hiding( substTy )
import CoreFVs         ( exprFreeVars )
import CoreArity       ( manifestArity, exprBotStrictness_maybe )
import CoreUtils
import Id
import DataCon
import TyCon
import Literal
import PrimOp
import IdInfo
import BasicTypes	( Arity )
import Type
import Coercion
import PrelNames
import VarEnv           ( mkInScopeSet )
import Bag
import Util
import Pair
import FastTypes
import FastString
import Outputable
import ForeignCall

import Data.Maybe
\end{code}


%************************************************************************
%*									*
\subsection{Making unfoldings}
%*									*
%************************************************************************

\begin{code}
mkTopUnfolding :: Bool -> CoreExpr -> Unfolding
mkTopUnfolding = mkUnfolding InlineRhs True {- Top level -}

mkImplicitUnfolding :: CoreExpr -> Unfolding
-- For implicit Ids, do a tiny bit of optimising first
mkImplicitUnfolding expr = mkTopUnfolding False (simpleOptExpr expr) 

-- Note [Top-level flag on inline rules]
-- ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
-- Slight hack: note that mk_inline_rules conservatively sets the
-- top-level flag to True.  It gets set more accurately by the simplifier
-- Simplify.simplUnfolding.

mkSimpleUnfolding :: CoreExpr -> Unfolding
mkSimpleUnfolding = mkUnfolding InlineRhs False False

mkDFunUnfolding :: Type -> [DFunArg CoreExpr] -> Unfolding
mkDFunUnfolding dfun_ty ops 
  = DFunUnfolding dfun_nargs data_con ops
  where
    (tvs, n_theta, cls, _) = tcSplitDFunTy dfun_ty
    dfun_nargs = length tvs + n_theta
    data_con   = classDataCon cls

mkWwInlineRule :: Id -> CoreExpr -> Arity -> Unfolding
mkWwInlineRule id expr arity
  = mkCoreUnfolding (InlineWrapper id) True
                   (simpleOptExpr expr) arity
                   (UnfWhen unSaturatedOk boringCxtNotOk)

mkCompulsoryUnfolding :: CoreExpr -> Unfolding
mkCompulsoryUnfolding expr	   -- Used for things that absolutely must be unfolded
  = mkCoreUnfolding InlineCompulsory True
                    (simpleOptExpr expr) 0    -- Arity of unfolding doesn't matter
                    (UnfWhen unSaturatedOk boringCxtOk)

mkInlineUnfolding :: Maybe Arity -> CoreExpr -> Unfolding
mkInlineUnfolding mb_arity expr 
  = mkCoreUnfolding InlineStable
    		    True 	 -- Note [Top-level flag on inline rules]
                    expr' arity 
		    (UnfWhen unsat_ok boring_ok)
  where
    expr' = simpleOptExpr expr
    (unsat_ok, arity) = case mb_arity of
                          Nothing -> (unSaturatedOk, manifestArity expr')
                          Just ar -> (needSaturated, ar)
              
    boring_ok = inlineBoringOk expr'

mkInlinableUnfolding :: CoreExpr -> Unfolding
mkInlinableUnfolding expr
  = mkUnfolding InlineStable True is_bot expr'
  where
    expr' = simpleOptExpr expr
    is_bot = isJust (exprBotStrictness_maybe expr')
\end{code}

Internal functions

\begin{code}
mkCoreUnfolding :: UnfoldingSource -> Bool -> CoreExpr
                -> Arity -> UnfoldingGuidance -> Unfolding
-- Occurrence-analyses the expression before capturing it
mkCoreUnfolding src top_lvl expr arity guidance 
  = CoreUnfolding { uf_tmpl   	  = occurAnalyseExpr expr,
    		    uf_src        = src,
    		    uf_arity      = arity,
		    uf_is_top 	  = top_lvl,
		    uf_is_value   = exprIsHNF        expr,
                    uf_is_conlike = exprIsConLike    expr,
		    uf_is_cheap   = exprIsCheap      expr,
		    uf_expandable = exprIsExpandable expr,
		    uf_guidance   = guidance }

mkUnfolding :: UnfoldingSource -> Bool -> Bool -> CoreExpr -> Unfolding
-- Calculates unfolding guidance
-- Occurrence-analyses the expression before capturing it
mkUnfolding src top_lvl is_bottoming expr
  | top_lvl && is_bottoming
  , not (exprIsTrivial expr)
  = NoUnfolding    -- See Note [Do not inline top-level bottoming functions]
  | otherwise
  = CoreUnfolding { uf_tmpl   	  = occurAnalyseExpr expr,
    		    uf_src        = src,
    		    uf_arity      = arity,
		    uf_is_top 	  = top_lvl,
		    uf_is_value   = exprIsHNF        expr,
                    uf_is_conlike = exprIsConLike    expr,
		    uf_expandable = exprIsExpandable expr,
		    uf_is_cheap   = is_cheap,
		    uf_guidance   = guidance }
  where
    is_cheap = exprIsCheap expr
    (arity, guidance) = calcUnfoldingGuidance is_cheap
                                              opt_UF_CreationThreshold expr
	-- Sometimes during simplification, there's a large let-bound thing	
	-- which has been substituted, and so is now dead; so 'expr' contains
	-- two copies of the thing while the occurrence-analysed expression doesn't
	-- Nevertheless, we *don't* occ-analyse before computing the size because the
	-- size computation bales out after a while, whereas occurrence analysis does not.
	--
	-- This can occasionally mean that the guidance is very pessimistic;
	-- it gets fixed up next round.  And it should be rare, because large
	-- let-bound things that are dead are usually caught by preInlineUnconditionally
\end{code}

%************************************************************************
%*									*
\subsection{The UnfoldingGuidance type}
%*									*
%************************************************************************

\begin{code}
inlineBoringOk :: CoreExpr -> Bool
-- See Note [INLINE for small functions]
-- True => the result of inlining the expression is 
--         no bigger than the expression itself
--     eg      (\x y -> f y x)
-- This is a quick and dirty version. It doesn't attempt
-- to deal with  (\x y z -> x (y z))
-- The really important one is (x `cast` c)
inlineBoringOk e
  = go 0 e
  where
    go :: Int -> CoreExpr -> Bool
    go credit (Lam x e) | isId x           = go (credit+1) e
                        | otherwise        = go credit e
    go credit (App f (Type {}))            = go credit f
    go credit (App f a) | credit > 0  
                        , exprIsTrivial a  = go (credit-1) f
    go credit (Note _ e) 		   = go credit e     
    go credit (Cast e _) 		   = go credit e
    go _      (Var {})         		   = boringCxtOk
    go _      _                		   = boringCxtNotOk

calcUnfoldingGuidance
	:: Bool		-- True <=> the rhs is cheap, or we want to treat it
	   		--          as cheap (INLINE things)	 
        -> Int		-- Bomb out if size gets bigger than this
	-> CoreExpr    	-- Expression to look at
	-> (Arity, UnfoldingGuidance)
calcUnfoldingGuidance expr_is_cheap bOMB_OUT_SIZE expr
  = case collectBinders expr of { (bndrs, body) ->
    let
        val_bndrs   = filter isId bndrs
	n_val_bndrs = length val_bndrs

    	guidance 
          = case (sizeExpr (iUnbox bOMB_OUT_SIZE) val_bndrs body) of
      	      TooBig -> UnfNever
      	      SizeIs size cased_bndrs scrut_discount
      	        | uncondInline n_val_bndrs (iBox size)
                , expr_is_cheap
      	        -> UnfWhen unSaturatedOk boringCxtOk   -- Note [INLINE for small functions]
	        | otherwise
      	        -> UnfIfGoodArgs { ug_args  = map (discount cased_bndrs) val_bndrs
      	                         , ug_size  = iBox size
      	        	  	 , ug_res   = iBox scrut_discount }

        discount cbs bndr
           = foldlBag (\acc (b',n) -> if bndr==b' then acc+n else acc) 
		      0 cbs
    in
    (n_val_bndrs, guidance) }
\end{code}

Note [Computing the size of an expression]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The basic idea of sizeExpr is obvious enough: count nodes.  But getting the
heuristics right has taken a long time.  Here's the basic strategy:

    * Variables, literals: 0
      (Exception for string literals, see litSize.)

    * Function applications (f e1 .. en): 1 + #value args

    * Constructor applications: 1, regardless of #args

    * Let(rec): 1 + size of components

    * Note, cast: 0

Examples

  Size	Term
  --------------
    0	  42#
    0	  x
    0     True
    2	  f x
    1	  Just x
    4 	  f (g x)

Notice that 'x' counts 0, while (f x) counts 2.  That's deliberate: there's
a function call to account for.  Notice also that constructor applications 
are very cheap, because exposing them to a caller is so valuable.


Note [Do not inline top-level bottoming functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The FloatOut pass has gone to some trouble to float out calls to 'error' 
and similar friends.  See Note [Bottoming floats] in SetLevels.
Do not re-inline them!  But we *do* still inline if they are very small
(the uncondInline stuff).


Note [INLINE for small functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider	{-# INLINE f #-}
                f x = Just x
                g y = f y
Then f's RHS is no larger than its LHS, so we should inline it into
even the most boring context.  In general, f the function is
sufficiently small that its body is as small as the call itself, the
inline unconditionally, regardless of how boring the context is.

Things to note:

 * We inline *unconditionally* if inlined thing is smaller (using sizeExpr)
   than the thing it's replacing.  Notice that
      (f x) --> (g 3) 		  -- YES, unconditionally
      (f x) --> x : []		  -- YES, *even though* there are two
      	    	    		  --      arguments to the cons
      x     --> g 3		  -- NO
      x	    --> Just v		  -- NO

  It's very important not to unconditionally replace a variable by
  a non-atomic term.

* We do this even if the thing isn't saturated, else we end up with the
  silly situation that
     f x y = x
     ...map (f 3)...
  doesn't inline.  Even in a boring context, inlining without being
  saturated will give a lambda instead of a PAP, and will be more
  efficient at runtime.

* However, when the function's arity > 0, we do insist that it 
  has at least one value argument at the call site.  Otherwise we find this:
       f = /\a \x:a. x
       d = /\b. MkD (f b)
  If we inline f here we get
       d = /\b. MkD (\x:b. x)
  and then prepareRhs floats out the argument, abstracting the type
  variables, so we end up with the original again!


\begin{code}
uncondInline :: Arity -> Int -> Bool
-- Inline unconditionally if there no size increase
-- Size of call is arity (+1 for the function)
-- See Note [INLINE for small functions]
uncondInline arity size 
  | arity == 0 = size == 0
  | otherwise  = size <= arity + 1
\end{code}


\begin{code}
sizeExpr :: FastInt 	    -- Bomb out if it gets bigger than this
	 -> [Id]	    -- Arguments; we're interested in which of these
			    -- get case'd
	 -> CoreExpr
	 -> ExprSize

-- Note [Computing the size of an expression]

sizeExpr bOMB_OUT_SIZE top_args expr
  = size_up expr
  where
    size_up (Cast e _) = size_up e
    size_up (Note _ e) = size_up e
    size_up (Type _)   = sizeZero           -- Types cost nothing
    size_up (Coercion _) = sizeZero
    size_up (Lit lit)  = sizeN (litSize lit)
    size_up (Var f)    = size_up_call f []  -- Make sure we get constructor
    	    	       	 	      	    -- discounts even on nullary constructors

    size_up (App fun (Type _)) = size_up fun
    size_up (App fun (Coercion _)) = size_up fun
    size_up (App fun arg)      = size_up arg  `addSizeNSD`
                                 size_up_app fun [arg]

    size_up (Lam b e) | isId b    = lamScrutDiscount (size_up e `addSizeN` 1)
		      | otherwise = size_up e

    size_up (Let (NonRec binder rhs) body)
      = size_up rhs		`addSizeNSD`
	size_up body		`addSizeN`
	(if isUnLiftedType (idType binder) then 0 else 1)
		-- For the allocation
		-- If the binder has an unlifted type there is no allocation

    size_up (Let (Rec pairs) body)
      = foldr (addSizeNSD . size_up . snd) 
              (size_up body `addSizeN` length pairs)	-- (length pairs) for the allocation
              pairs

    size_up (Case (Var v) _ _ alts) 
	| v `elem` top_args		-- We are scrutinising an argument variable
	= alts_size (foldr1 addAltSize alt_sizes)
		    (foldr1 maxSize alt_sizes)
		-- Good to inline if an arg is scrutinised, because
		-- that may eliminate allocation in the caller
		-- And it eliminates the case itself
	where
	  alt_sizes = map size_up_alt alts

		-- alts_size tries to compute a good discount for
		-- the case when we are scrutinising an argument variable
	  alts_size (SizeIs tot tot_disc tot_scrut)  -- Size of all alternatives
		    (SizeIs max _        _)          -- Size of biggest alternative
	 	= SizeIs tot (unitBag (v, iBox (_ILIT(2) +# tot -# max)) `unionBags` tot_disc) tot_scrut
			-- If the variable is known, we produce a discount that
			-- will take us back to 'max', the size of the largest alternative
			-- The 1+ is a little discount for reduced allocation in the caller
			--
			-- Notice though, that we return tot_disc, the total discount from 
			-- all branches.  I think that's right.

	  alts_size tot_size _ = tot_size

    size_up (Case e b _ alts) = size_up e  `addSizeNSD`
                                foldr (addAltSize . size_up_alt) case_size alts
      where
          case_size
           | is_inline_scrut e, not (lengthExceeds alts 1)  = sizeN (-1)
           | otherwise = sizeZero
                -- Normally we don't charge for the case itself, but
                -- we charge one per alternative (see size_up_alt,
                -- below) to account for the cost of the info table
                -- and comparisons.
                --
                -- However, in certain cases (see is_inline_scrut
                -- below), no code is generated for the case unless
                -- there are multiple alts.  In these cases we
                -- subtract one, making the first alt free.
                -- e.g. case x# +# y# of _ -> ...   should cost 1
                --      case touch# x# of _ -> ...  should cost 0
                -- (see #4978)
                --
                -- I would like to not have the "not (lengthExceeds alts 1)"
                -- condition above, but without that some programs got worse
                -- (spectral/hartel/event and spectral/para).  I don't fully
                -- understand why. (SDM 24/5/11)

                -- unboxed variables, inline primops and unsafe foreign calls
                -- are all "inline" things:
          is_inline_scrut (Var v) = isUnLiftedType (idType v)
          is_inline_scrut scrut
              | (Var f, _) <- collectArgs scrut
                = case idDetails f of
                    FCallId fc  -> not (isSafeForeignCall fc)
                    PrimOpId op -> not (primOpOutOfLine op)
                    _other      -> False
              | otherwise
                = False

    ------------ 
    -- size_up_app is used when there's ONE OR MORE value args
    size_up_app (App fun arg) args 
	| isTyCoArg arg		   = size_up_app fun args
	| otherwise		   = size_up arg  `addSizeNSD`
                                     size_up_app fun (arg:args)
    size_up_app (Var fun)     args = size_up_call fun args
    size_up_app other         args = size_up other `addSizeN` length args

    ------------ 
    size_up_call :: Id -> [CoreExpr] -> ExprSize
    size_up_call fun val_args
       = case idDetails fun of
           FCallId _        -> sizeN opt_UF_DearOp
           DataConWorkId dc -> conSize    dc (length val_args)
           PrimOpId op      -> primOpSize op (length val_args)
	   ClassOpId _ 	    -> classOpSize top_args val_args
	   _     	    -> funSize top_args fun (length val_args)

    ------------ 
    size_up_alt (_con, _bndrs, rhs) = size_up rhs `addSizeN` 1
 	-- Don't charge for args, so that wrappers look cheap
	-- (See comments about wrappers with Case)
	--
	-- IMPORATANT: *do* charge 1 for the alternative, else we 
	-- find that giant case nests are treated as practically free
	-- A good example is Foreign.C.Error.errrnoToIOError

    ------------
	-- These addSize things have to be here because
	-- I don't want to give them bOMB_OUT_SIZE as an argument
    addSizeN TooBig          _  = TooBig
    addSizeN (SizeIs n xs d) m 	= mkSizeIs bOMB_OUT_SIZE (n +# iUnbox m) xs d
    
        -- addAltSize is used to add the sizes of case alternatives
    addAltSize TooBig	         _	= TooBig
    addAltSize _		 TooBig	= TooBig
    addAltSize (SizeIs n1 xs d1) (SizeIs n2 ys d2) 
	= mkSizeIs bOMB_OUT_SIZE (n1 +# n2) 
                                 (xs `unionBags` ys) 
                                 (d1 +# d2)   -- Note [addAltSize result discounts]

        -- This variant ignores the result discount from its LEFT argument
	-- It's used when the second argument isn't part of the result
    addSizeNSD TooBig	         _	= TooBig
    addSizeNSD _		 TooBig	= TooBig
    addSizeNSD (SizeIs n1 xs _) (SizeIs n2 ys d2) 
	= mkSizeIs bOMB_OUT_SIZE (n1 +# n2) 
                                 (xs `unionBags` ys) 
                                 d2  -- Ignore d1
\end{code}

\begin{code}
-- | Finds a nominal size of a string literal.
litSize :: Literal -> Int
-- Used by CoreUnfold.sizeExpr
litSize (MachStr str) = 1 + ((lengthFS str + 3) `div` 4)
	-- If size could be 0 then @f "x"@ might be too small
	-- [Sept03: make literal strings a bit bigger to avoid fruitless 
	--  duplication of little strings]
litSize _other = 0    -- Must match size of nullary constructors
	       	      -- Key point: if  x |-> 4, then x must inline unconditionally
		      --     	    (eg via case binding)

classOpSize :: [Id] -> [CoreExpr] -> ExprSize
-- See Note [Conlike is interesting]
classOpSize _ [] 
  = sizeZero
classOpSize top_args (arg1 : other_args)
  = SizeIs (iUnbox size) arg_discount (_ILIT(0))
  where
    size = 2 + length other_args
    -- If the class op is scrutinising a lambda bound dictionary then
    -- give it a discount, to encourage the inlining of this function
    -- The actual discount is rather arbitrarily chosen
    arg_discount = case arg1 of
    		     Var dict | dict `elem` top_args 
		     	      -> unitBag (dict, opt_UF_DictDiscount)
		     _other   -> emptyBag
    		     
funSize :: [Id] -> Id -> Int -> ExprSize
-- Size for functions that are not constructors or primops
-- Note [Function applications]
funSize top_args fun n_val_args
  | fun `hasKey` buildIdKey   = buildSize
  | fun `hasKey` augmentIdKey = augmentSize
  | otherwise = SizeIs (iUnbox size) arg_discount (iUnbox res_discount)
  where
    some_val_args = n_val_args > 0

    arg_discount | some_val_args && fun `elem` top_args
    		 = unitBag (fun, opt_UF_FunAppDiscount)
		 | otherwise = emptyBag
	-- If the function is an argument and is applied
	-- to some values, give it an arg-discount

    res_discount | idArity fun > n_val_args = opt_UF_FunAppDiscount
    		 | otherwise   	 	    = 0
        -- If the function is partially applied, show a result discount

    size | some_val_args = 1 + n_val_args
         | otherwise     = 0
	-- The 1+ is for the function itself
	-- Add 1 for each non-trivial arg;
	-- the allocation cost, as in let(rec)
  

conSize :: DataCon -> Int -> ExprSize
conSize dc n_val_args
  | n_val_args == 0 = SizeIs (_ILIT(0)) emptyBag (_ILIT(1))	-- Like variables

-- See Note [Constructor size]
  | isUnboxedTupleCon dc = SizeIs (_ILIT(0)) emptyBag (iUnbox n_val_args +# _ILIT(1))

-- See Note [Unboxed tuple result discount]
--  | isUnboxedTupleCon dc = SizeIs (_ILIT(0)) emptyBag (_ILIT(0))

-- See Note [Constructor size]
  | otherwise = SizeIs (_ILIT(1)) emptyBag (iUnbox n_val_args +# _ILIT(1))
\end{code}

Note [Constructor size]
~~~~~~~~~~~~~~~~~~~~~~~
Treat a constructors application as size 1, regardless of how many
arguments it has; we are keen to expose them (and we charge separately
for their args).  We can't treat them as size zero, else we find that
(Just x) has size 0, which is the same as a lone variable; and hence
'v' will always be replaced by (Just x), where v is bound to Just x.

However, unboxed tuples count as size zero. I found occasions where we had 
	f x y z = case op# x y z of { s -> (# s, () #) }
and f wasn't getting inlined.

Note [Unboxed tuple result discount]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
I tried giving unboxed tuples a *result discount* of zero (see the
commented-out line).  Why?  When returned as a result they do not
allocate, so maybe we don't want to charge so much for them If you
have a non-zero discount here, we find that workers often get inlined
back into wrappers, because it look like
    f x = case $wf x of (# a,b #) -> (a,b)
and we are keener because of the case.  However while this change
shrank binary sizes by 0.5% it also made spectral/boyer allocate 5%
more. All other changes were very small. So it's not a big deal but I
didn't adopt the idea.

\begin{code}
primOpSize :: PrimOp -> Int -> ExprSize
primOpSize op n_val_args
 | not (primOpIsDupable op) = sizeN opt_UF_DearOp
 | not (primOpOutOfLine op) = sizeN 1
	-- Be very keen to inline simple primops.
	-- We give a discount of 1 for each arg so that (op# x y z) costs 2.
	-- We can't make it cost 1, else we'll inline let v = (op# x y z) 
	-- at every use of v, which is excessive.
	--
	-- A good example is:
	--	let x = +# p q in C {x}
	-- Even though x get's an occurrence of 'many', its RHS looks cheap,
	-- and there's a good chance it'll get inlined back into C's RHS. Urgh!

 | otherwise = sizeN n_val_args


buildSize :: ExprSize
buildSize = SizeIs (_ILIT(0)) emptyBag (_ILIT(4))
	-- We really want to inline applications of build
	-- build t (\cn -> e) should cost only the cost of e (because build will be inlined later)
	-- Indeed, we should add a result_discount becuause build is 
	-- very like a constructor.  We don't bother to check that the
	-- build is saturated (it usually is).  The "-2" discounts for the \c n, 
	-- The "4" is rather arbitrary.

augmentSize :: ExprSize
augmentSize = SizeIs (_ILIT(0)) emptyBag (_ILIT(4))
	-- Ditto (augment t (\cn -> e) ys) should cost only the cost of
	-- e plus ys. The -2 accounts for the \cn 

-- When we return a lambda, give a discount if it's used (applied)
lamScrutDiscount :: ExprSize -> ExprSize
lamScrutDiscount (SizeIs n vs _) = SizeIs n vs (iUnbox opt_UF_FunAppDiscount)
lamScrutDiscount TooBig          = TooBig
\end{code}

Note [addAltSize result discounts]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When adding the size of alternatives, we *add* the result discounts
too, rather than take the *maximum*.  For a multi-branch case, this
gives a discount for each branch that returns a constructor, making us
keener to inline.  I did try using 'max' instead, but it makes nofib 
'rewrite' and 'puzzle' allocate significantly more, and didn't make
binary sizes shrink significantly either.

Note [Discounts and thresholds]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Constants for discounts and thesholds are defined in main/StaticFlags,
all of form opt_UF_xxxx.   They are:

opt_UF_CreationThreshold (45)
     At a definition site, if the unfolding is bigger than this, we
     may discard it altogether

opt_UF_UseThreshold (6)
     At a call site, if the unfolding, less discounts, is smaller than
     this, then it's small enough inline

opt_UF_KeennessFactor (1.5)
     Factor by which the discounts are multiplied before 
     subtracting from size

opt_UF_DictDiscount (1)
     The discount for each occurrence of a dictionary argument
     as an argument of a class method.  Should be pretty small
     else big functions may get inlined

opt_UF_FunAppDiscount (6)
     Discount for a function argument that is applied.  Quite
     large, because if we inline we avoid the higher-order call.

opt_UF_DearOp (4)
     The size of a foreign call or not-dupable PrimOp


Note [Function applications]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
In a function application (f a b)

  - If 'f' is an argument to the function being analysed, 
    and there's at least one value arg, record a FunAppDiscount for f

  - If the application if a PAP (arity > 2 in this example)
    record a *result* discount (because inlining
    with "extra" args in the call may mean that we now 
    get a saturated application)

Code for manipulating sizes

\begin{code}
data ExprSize = TooBig
	      | SizeIs FastInt		-- Size found
		       (Bag (Id,Int))	-- Arguments cased herein, and discount for each such
		       FastInt		-- Size to subtract if result is scrutinised 
					-- by a case expression

instance Outputable ExprSize where
  ppr TooBig         = ptext (sLit "TooBig")
  ppr (SizeIs a _ c) = brackets (int (iBox a) <+> int (iBox c))

-- subtract the discount before deciding whether to bale out. eg. we
-- want to inline a large constructor application into a selector:
--  	tup = (a_1, ..., a_99)
--  	x = case tup of ...
--
mkSizeIs :: FastInt -> FastInt -> Bag (Id, Int) -> FastInt -> ExprSize
mkSizeIs max n xs d | (n -# d) ># max = TooBig
		    | otherwise	      = SizeIs n xs d
 
maxSize :: ExprSize -> ExprSize -> ExprSize
maxSize TooBig         _ 				  = TooBig
maxSize _              TooBig				  = TooBig
maxSize s1@(SizeIs n1 _ _) s2@(SizeIs n2 _ _) | n1 ># n2  = s1
					      | otherwise = s2

sizeZero :: ExprSize
sizeN :: Int -> ExprSize

sizeZero = SizeIs (_ILIT(0))  emptyBag (_ILIT(0))
sizeN n  = SizeIs (iUnbox n) emptyBag (_ILIT(0))
\end{code}


%************************************************************************
%*									*
\subsection[considerUnfolding]{Given all the info, do (not) do the unfolding}
%*									*
%************************************************************************

We use 'couldBeSmallEnoughToInline' to avoid exporting inlinings that
we ``couldn't possibly use'' on the other side.  Can be overridden w/
flaggery.  Just the same as smallEnoughToInline, except that it has no
actual arguments.

\begin{code}
couldBeSmallEnoughToInline :: Int -> CoreExpr -> Bool
couldBeSmallEnoughToInline threshold rhs 
  = case sizeExpr (iUnbox threshold) [] body of
       TooBig -> False
       _      -> True
  where
    (_, body) = collectBinders rhs

----------------
smallEnoughToInline :: Unfolding -> Bool
smallEnoughToInline (CoreUnfolding {uf_guidance = UnfIfGoodArgs {ug_size = size}})
  = size <= opt_UF_UseThreshold
smallEnoughToInline _
  = False

----------------
certainlyWillInline :: Unfolding -> Bool
  -- Sees if the unfolding is pretty certain to inline	
certainlyWillInline (CoreUnfolding { uf_is_cheap = is_cheap, uf_arity = n_vals, uf_guidance = guidance })
  = case guidance of
      UnfNever      -> False
      UnfWhen {}    -> True
      UnfIfGoodArgs { ug_size = size} 
                    -> is_cheap && size - (n_vals +1) <= opt_UF_UseThreshold

certainlyWillInline _
  = False
\end{code}

%************************************************************************
%*									*
\subsection{callSiteInline}
%*									*
%************************************************************************

This is the key function.  It decides whether to inline a variable at a call site

callSiteInline is used at call sites, so it is a bit more generous.
It's a very important function that embodies lots of heuristics.
A non-WHNF can be inlined if it doesn't occur inside a lambda,
and occurs exactly once or 
    occurs once in each branch of a case and is small

If the thing is in WHNF, there's no danger of duplicating work, 
so we can inline if it occurs once, or is small

NOTE: we don't want to inline top-level functions that always diverge.
It just makes the code bigger.  Tt turns out that the convenient way to prevent
them inlining is to give them a NOINLINE pragma, which we do in 
StrictAnal.addStrictnessInfoToTopId

\begin{code}
callSiteInline :: DynFlags
	       -> Id			-- The Id
	       -> Bool			-- True <=> unfolding is active
	       -> Bool			-- True if there are are no arguments at all (incl type args)
	       -> [ArgSummary]		-- One for each value arg; True if it is interesting
	       -> CallCtxt		-- True <=> continuation is interesting
	       -> Maybe CoreExpr	-- Unfolding, if any

instance Outputable ArgSummary where
  ppr TrivArg    = ptext (sLit "TrivArg")
  ppr NonTrivArg = ptext (sLit "NonTrivArg")
  ppr ValueArg   = ptext (sLit "ValueArg")

data CallCtxt = BoringCtxt

	      | ArgCtxt		-- We are somewhere in the argument of a function
                        Bool	-- True  <=> we're somewhere in the RHS of function with rules
				-- False <=> we *are* the argument of a function with non-zero
				-- 	     arg discount
                                --        OR 
                                --           we *are* the RHS of a let  Note [RHS of lets]
                                -- In both cases, be a little keener to inline

	      | ValAppCtxt 	-- We're applied to at least one value arg
				-- This arises when we have ((f x |> co) y)
				-- Then the (f x) has argument 'x' but in a ValAppCtxt

	      | CaseCtxt	-- We're the scrutinee of a case
				-- that decomposes its scrutinee

instance Outputable CallCtxt where
  ppr BoringCtxt      = ptext (sLit "BoringCtxt")
  ppr (ArgCtxt rules) = ptext (sLit "ArgCtxt") <+> ppr rules
  ppr CaseCtxt 	      = ptext (sLit "CaseCtxt")
  ppr ValAppCtxt      = ptext (sLit "ValAppCtxt")

callSiteInline dflags id active_unfolding lone_variable arg_infos cont_info
  = case idUnfolding id of 
      -- idUnfolding checks for loop-breakers, returning NoUnfolding
      -- Things with an INLINE pragma may have an unfolding *and* 
      -- be a loop breaker  (maybe the knot is not yet untied)
	CoreUnfolding { uf_tmpl = unf_template, uf_is_top = is_top 
		      , uf_is_cheap = is_cheap, uf_arity = uf_arity
                      , uf_guidance = guidance, uf_expandable = is_exp }
          | active_unfolding -> tryUnfolding dflags id lone_variable 
                                    arg_infos cont_info unf_template is_top 
                                    is_cheap is_exp uf_arity guidance
          | otherwise    -> Nothing
	NoUnfolding 	 -> Nothing 
	OtherCon {} 	 -> Nothing 
	DFunUnfolding {} -> Nothing 	-- Never unfold a DFun

tryUnfolding :: DynFlags -> Id -> Bool -> [ArgSummary] -> CallCtxt
             -> CoreExpr -> Bool -> Bool -> Bool -> Arity -> UnfoldingGuidance
	     -> Maybe CoreExpr	
tryUnfolding dflags id lone_variable 
             arg_infos cont_info unf_template is_top 
             is_cheap is_exp uf_arity guidance
			-- uf_arity will typically be equal to (idArity id), 
			-- but may be less for InlineRules
 | dopt Opt_D_dump_inlinings dflags && dopt Opt_D_verbose_core2core dflags
 = pprTrace ("Considering inlining: " ++ showSDoc (ppr id))
		 (vcat [text "arg infos" <+> ppr arg_infos,
			text "uf arity" <+> ppr uf_arity,
			text "interesting continuation" <+> ppr cont_info,
			text "some_benefit" <+> ppr some_benefit,
                        text "is exp:" <+> ppr is_exp,
                        text "is cheap:" <+> ppr is_cheap,
			text "guidance" <+> ppr guidance,
			extra_doc,
			text "ANSWER =" <+> if yes_or_no then text "YES" else text "NO"])
	         result
  | otherwise  = result

  where
    n_val_args = length arg_infos
    saturated  = n_val_args >= uf_arity

    result | yes_or_no = Just unf_template
           | otherwise = Nothing

    interesting_args = any nonTriv arg_infos 
    	-- NB: (any nonTriv arg_infos) looks at the
    	-- over-saturated args too which is "wrong"; 
    	-- but if over-saturated we inline anyway.

           -- some_benefit is used when the RHS is small enough
           -- and the call has enough (or too many) value
           -- arguments (ie n_val_args >= arity). But there must
           -- be *something* interesting about some argument, or the
           -- result context, to make it worth inlining
    some_benefit 
       | not saturated = interesting_args	-- Under-saturated
    	   	      		     	-- Note [Unsaturated applications]
       | n_val_args > uf_arity = True	-- Over-saturated
       | otherwise = interesting_args	-- Saturated
                  || interesting_saturated_call 

    interesting_saturated_call 
      = case cont_info of
          BoringCtxt -> not is_top && uf_arity > 0	  -- Note [Nested functions]
          CaseCtxt   -> not (lone_variable && is_cheap)   -- Note [Lone variables]
          ArgCtxt {} -> uf_arity > 0     		  -- Note [Inlining in ArgCtxt]
          ValAppCtxt -> True			          -- Note [Cast then apply]

    (yes_or_no, extra_doc)
      = case guidance of
          UnfNever -> (False, empty)

          UnfWhen unsat_ok boring_ok 
             -> (enough_args && (boring_ok || some_benefit), empty )
             where      -- See Note [INLINE for small functions]
               enough_args = saturated || (unsat_ok && n_val_args > 0)

          UnfIfGoodArgs { ug_args = arg_discounts, ug_res = res_discount, ug_size = size }
      	     -> ( is_cheap && some_benefit && small_enough
                , (text "discounted size =" <+> int discounted_size) )
    	     where
    	       discounted_size = size - discount
    	       small_enough = discounted_size <= opt_UF_UseThreshold
    	       discount = computeDiscount uf_arity arg_discounts 
    	         		          res_discount arg_infos cont_info
\end{code}

Note [RHS of lets]
~~~~~~~~~~~~~~~~~~
Be a tiny bit keener to inline in the RHS of a let, because that might
lead to good thing later
     f y = (y,y,y)
     g y = let x = f y in ...(case x of (a,b,c) -> ...) ...
We'd inline 'f' if the call was in a case context, and it kind-of-is,
only we can't see it.  So we treat the RHS of a let as not-totally-boring.
    
Note [Unsaturated applications]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When a call is not saturated, we *still* inline if one of the
arguments has interesting structure.  That's sometimes very important.
A good example is the Ord instance for Bool in Base:

 Rec {
    $fOrdBool =GHC.Classes.D:Ord
        	 @ Bool
      		 ...
      		 $cmin_ajX

    $cmin_ajX [Occ=LoopBreaker] :: Bool -> Bool -> Bool
    $cmin_ajX = GHC.Classes.$dmmin @ Bool $fOrdBool
  }

But the defn of GHC.Classes.$dmmin is:

  $dmmin :: forall a. GHC.Classes.Ord a => a -> a -> a
    {- Arity: 3, HasNoCafRefs, Strictness: SLL,
       Unfolding: (\ @ a $dOrd :: GHC.Classes.Ord a x :: a y :: a ->
                   case @ a GHC.Classes.<= @ a $dOrd x y of wild {
                     GHC.Types.False -> y GHC.Types.True -> x }) -}

We *really* want to inline $dmmin, even though it has arity 3, in
order to unravel the recursion.


Note [Things to watch]
~~~~~~~~~~~~~~~~~~~~~~
*   { y = I# 3; x = y `cast` co; ...case (x `cast` co) of ... }
    Assume x is exported, so not inlined unconditionally.
    Then we want x to inline unconditionally; no reason for it 
    not to, and doing so avoids an indirection.

*   { x = I# 3; ....f x.... }
    Make sure that x does not inline unconditionally!  
    Lest we get extra allocation.

Note [Inlining an InlineRule]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
An InlineRules is used for
  (a) programmer INLINE pragmas
  (b) inlinings from worker/wrapper

For (a) the RHS may be large, and our contract is that we *only* inline
when the function is applied to all the arguments on the LHS of the
source-code defn.  (The uf_arity in the rule.)

However for worker/wrapper it may be worth inlining even if the 
arity is not satisfied (as we do in the CoreUnfolding case) so we don't
require saturation.


Note [Nested functions]
~~~~~~~~~~~~~~~~~~~~~~~
If a function has a nested defn we also record some-benefit, on the
grounds that we are often able to eliminate the binding, and hence the
allocation, for the function altogether; this is good for join points.
But this only makes sense for *functions*; inlining a constructor
doesn't help allocation unless the result is scrutinised.  UNLESS the
constructor occurs just once, albeit possibly in multiple case
branches.  Then inlining it doesn't increase allocation, but it does
increase the chance that the constructor won't be allocated at all in
the branches that don't use it.

Note [Cast then apply]
~~~~~~~~~~~~~~~~~~~~~~
Consider
   myIndex = __inline_me ( (/\a. <blah>) |> co )
   co :: (forall a. a -> a) ~ (forall a. T a)
     ... /\a.\x. case ((myIndex a) |> sym co) x of { ... } ...

We need to inline myIndex to unravel this; but the actual call (myIndex a) has
no value arguments.  The ValAppCtxt gives it enough incentive to inline.

Note [Inlining in ArgCtxt]
~~~~~~~~~~~~~~~~~~~~~~~~~~
The condition (arity > 0) here is very important, because otherwise
we end up inlining top-level stuff into useless places; eg
   x = I# 3#
   f = \y.  g x
This can make a very big difference: it adds 16% to nofib 'integer' allocs,
and 20% to 'power'.

At one stage I replaced this condition by 'True' (leading to the above 
slow-down).  The motivation was test eyeball/inline1.hs; but that seems
to work ok now.

NOTE: arguably, we should inline in ArgCtxt only if the result of the
call is at least CONLIKE.  At least for the cases where we use ArgCtxt
for the RHS of a 'let', we only profit from the inlining if we get a 
CONLIKE thing (modulo lets).

Note [Lone variables]	See also Note [Interaction of exprIsCheap and lone variables]
~~~~~~~~~~~~~~~~~~~~~   which appears below
The "lone-variable" case is important.  I spent ages messing about
with unsatisfactory varaints, but this is nice.  The idea is that if a
variable appears all alone

	as an arg of lazy fn, or rhs	BoringCtxt
	as scrutinee of a case		CaseCtxt
	as arg of a fn			ArgCtxt
AND
	it is bound to a cheap expression

then we should not inline it (unless there is some other reason,
e.g. is is the sole occurrence).  That is what is happening at 
the use of 'lone_variable' in 'interesting_saturated_call'.

Why?  At least in the case-scrutinee situation, turning
	let x = (a,b) in case x of y -> ...
into
	let x = (a,b) in case (a,b) of y -> ...
and thence to 
	let x = (a,b) in let y = (a,b) in ...
is bad if the binding for x will remain.

Another example: I discovered that strings
were getting inlined straight back into applications of 'error'
because the latter is strict.
	s = "foo"
	f = \x -> ...(error s)...

Fundamentally such contexts should not encourage inlining because the
context can ``see'' the unfolding of the variable (e.g. case or a
RULE) so there's no gain.  If the thing is bound to a value.

However, watch out:

 * Consider this:
	foo = _inline_ (\n. [n])
	bar = _inline_ (foo 20)
	baz = \n. case bar of { (m:_) -> m + n }
   Here we really want to inline 'bar' so that we can inline 'foo'
   and the whole thing unravels as it should obviously do.  This is 
   important: in the NDP project, 'bar' generates a closure data
   structure rather than a list. 

   So the non-inlining of lone_variables should only apply if the
   unfolding is regarded as cheap; because that is when exprIsConApp_maybe
   looks through the unfolding.  Hence the "&& is_cheap" in the
   InlineRule branch.

 * Even a type application or coercion isn't a lone variable.
   Consider
	case $fMonadST @ RealWorld of { :DMonad a b c -> c }
   We had better inline that sucker!  The case won't see through it.

   For now, I'm treating treating a variable applied to types 
   in a *lazy* context "lone". The motivating example was
	f = /\a. \x. BIG
	g = /\a. \y.  h (f a)
   There's no advantage in inlining f here, and perhaps
   a significant disadvantage.  Hence some_val_args in the Stop case

Note [Interaction of exprIsCheap and lone variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The lone-variable test says "don't inline if a case expression
scrutines a lone variable whose unfolding is cheap".  It's very 
important that, under these circumstances, exprIsConApp_maybe
can spot a constructor application. So, for example, we don't
consider
	let x = e in (x,x)
to be cheap, and that's good because exprIsConApp_maybe doesn't
think that expression is a constructor application.

I used to test is_value rather than is_cheap, which was utterly
wrong, because the above expression responds True to exprIsHNF.

This kind of thing can occur if you have

	{-# INLINE foo #-}
	foo = let x = e in (x,x)

which Roman did.

\begin{code}
computeDiscount :: Int -> [Int] -> Int -> [ArgSummary] -> CallCtxt -> Int
computeDiscount n_vals_wanted arg_discounts res_discount arg_infos cont_info
 	-- We multiple the raw discounts (args_discount and result_discount)
	-- ty opt_UnfoldingKeenessFactor because the former have to do with
	--  *size* whereas the discounts imply that there's some extra 
	--  *efficiency* to be gained (e.g. beta reductions, case reductions) 
	-- by inlining.

  = 1 		-- Discount of 1 because the result replaces the call
		-- so we count 1 for the function itself

    + length (take n_vals_wanted arg_infos)
      	       -- Discount of (un-scaled) 1 for each arg supplied, 
   	       -- because the result replaces the call

    + round (opt_UF_KeenessFactor * 
	     fromIntegral (arg_discount + res_discount'))
  where
    arg_discount = sum (zipWith mk_arg_discount arg_discounts arg_infos)

    mk_arg_discount _ 	     TrivArg    = 0 
    mk_arg_discount _ 	     NonTrivArg = 1   
    mk_arg_discount discount ValueArg   = discount 

    res_discount' = case cont_info of
			BoringCtxt  -> 0
			CaseCtxt    -> res_discount
			_other      -> 4 `min` res_discount
		-- res_discount can be very large when a function returns
		-- constructors; but we only want to invoke that large discount
		-- when there's a case continuation.
		-- Otherwise we, rather arbitrarily, threshold it.  Yuk.
		-- But we want to aovid inlining large functions that return 
		-- constructors into contexts that are simply "interesting"
\end{code}

%************************************************************************
%*									*
	Interesting arguments
%*									*
%************************************************************************

Note [Interesting arguments]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
An argument is interesting if it deserves a discount for unfoldings
with a discount in that argument position.  The idea is to avoid
unfolding a function that is applied only to variables that have no
unfolding (i.e. they are probably lambda bound): f x y z There is
little point in inlining f here.

Generally, *values* (like (C a b) and (\x.e)) deserve discounts.  But
we must look through lets, eg (let x = e in C a b), because the let will
float, exposing the value, if we inline.  That makes it different to
exprIsHNF.

Before 2009 we said it was interesting if the argument had *any* structure
at all; i.e. (hasSomeUnfolding v).  But does too much inlining; see Trac #3016.

But we don't regard (f x y) as interesting, unless f is unsaturated.
If it's saturated and f hasn't inlined, then it's probably not going
to now!

Note [Conlike is interesting]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
	f d = ...((*) d x y)...
	... f (df d')...
where df is con-like. Then we'd really like to inline 'f' so that the
rule for (*) (df d) can fire.  To do this 
  a) we give a discount for being an argument of a class-op (eg (*) d)
  b) we say that a con-like argument (eg (df d)) is interesting

\begin{code}
data ArgSummary = TrivArg	-- Nothing interesting
     		| NonTrivArg	-- Arg has structure
		| ValueArg	-- Arg is a con-app or PAP
		  		-- ..or con-like. Note [Conlike is interesting]

interestingArg :: CoreExpr -> ArgSummary
-- See Note [Interesting arguments]
interestingArg e = go e 0
  where
    -- n is # value args to which the expression is applied
    go (Lit {}) _   	   = ValueArg
    go (Var v)  n
       | isConLikeId v     = ValueArg	-- Experimenting with 'conlike' rather that
       	 	     	     		--    data constructors here
       | idArity v > n	   = ValueArg	-- Catches (eg) primops with arity but no unfolding
       | n > 0	           = NonTrivArg	-- Saturated or unknown call
       | conlike_unfolding = ValueArg	-- n==0; look for an interesting unfolding
                                        -- See Note [Conlike is interesting]
       | otherwise	   = TrivArg	-- n==0, no useful unfolding
       where
         conlike_unfolding = isConLikeUnfolding (idUnfolding v)

    go (Type _)          _ = TrivArg
    go (Coercion _)      _ = TrivArg
    go (App fn (Type _)) n = go fn n
    go (App fn (Coercion _)) n = go fn n
    go (App fn _)        n = go fn (n+1)
    go (Note _ a) 	 n = go a n
    go (Cast e _) 	 n = go e n
    go (Lam v e)  	 n 
       | isTyVar v	   = go e n
       | n>0	 	   = go e (n-1)
       | otherwise	   = ValueArg
    go (Let _ e)  	 n = case go e n of { ValueArg -> ValueArg; _ -> NonTrivArg }
    go (Case {})  	 _ = NonTrivArg

nonTriv ::  ArgSummary -> Bool
nonTriv TrivArg = False
nonTriv _       = True
\end{code}

%************************************************************************
%*									*
         exprIsConApp_maybe
%*									*
%************************************************************************

Note [exprIsConApp_maybe]
~~~~~~~~~~~~~~~~~~~~~~~~~
exprIsConApp_maybe is a very important function.  There are two principal
uses:
  * case e of { .... }
  * cls_op e, where cls_op is a class operation

In both cases you want to know if e is of form (C e1..en) where C is
a data constructor.

However e might not *look* as if 

\begin{code}
-- | Returns @Just (dc, [t1..tk], [x1..xn])@ if the argument expression is 
-- a *saturated* constructor application of the form @dc t1..tk x1 .. xn@,
-- where t1..tk are the *universally-qantified* type args of 'dc'
exprIsConApp_maybe :: IdUnfoldingFun -> CoreExpr -> Maybe (DataCon, [Type], [CoreExpr])

exprIsConApp_maybe id_unf (Note note expr)
  | notSccNote note
  = exprIsConApp_maybe id_unf expr
	-- We ignore all notes except SCCs.  For example,
	--  	case _scc_ "foo" (C a b) of
	--			C a b -> e
	-- should not be optimised away, because we'll lose the
	-- entry count on 'foo'; see Trac #4414

exprIsConApp_maybe id_unf (Cast expr co)
  =     -- Here we do the KPush reduction rule as described in the FC paper
	-- The transformation applies iff we have
	--	(C e1 ... en) `cast` co
	-- where co :: (T t1 .. tn) ~ to_ty
	-- The left-hand one must be a T, because exprIsConApp returned True
	-- but the right-hand one might not be.  (Though it usually will.)

    case exprIsConApp_maybe id_unf expr of {
	Nothing 	                 -> Nothing ;
	Just (dc, _dc_univ_args, dc_args) -> 

    let Pair _from_ty to_ty = coercionKind co
	dc_tc = dataConTyCon dc
    in
    case splitTyConApp_maybe to_ty of {
	Nothing -> Nothing ;
	Just (to_tc, to_tc_arg_tys) 
		| dc_tc /= to_tc -> Nothing
		-- These two Nothing cases are possible; we might see 
		--	(C x y) `cast` (g :: T a ~ S [a]),
		-- where S is a type function.  In fact, exprIsConApp
		-- will probably not be called in such circumstances,
		-- but there't nothing wrong with it 

	 	| otherwise  ->
    let
	tc_arity       = tyConArity dc_tc
	dc_univ_tyvars = dataConUnivTyVars dc
        dc_ex_tyvars   = dataConExTyVars dc
        arg_tys        = dataConRepArgTys dc

        (ex_args, val_args) = splitAtList dc_ex_tyvars dc_args

	-- Make the "theta" from Fig 3 of the paper
        gammas = decomposeCo tc_arity co
        theta  = zipOpenCvSubst (dc_univ_tyvars ++ dc_ex_tyvars)
                                (gammas         ++ map mkReflCo (stripTypeArgs ex_args))

          -- Cast the value arguments (which include dictionaries)
	new_val_args = zipWith cast_arg arg_tys val_args
	cast_arg arg_ty arg = mkCoerce (liftCoSubst theta arg_ty) arg
    in
#ifdef DEBUG
    let dump_doc = vcat [ppr dc,      ppr dc_univ_tyvars, ppr dc_ex_tyvars,
                         ppr arg_tys, ppr dc_args,        ppr _dc_univ_args,
                         ppr ex_args, ppr val_args]
    in
    ASSERT2( eqType _from_ty (mkTyConApp dc_tc _dc_univ_args), dump_doc )
    ASSERT2( all isTypeArg ex_args, dump_doc )
    ASSERT2( equalLength val_args arg_tys, dump_doc )
#endif

    Just (dc, to_tc_arg_tys, ex_args ++ new_val_args)
    }}

exprIsConApp_maybe id_unf expr 
  = analyse expr [] 
  where
    analyse (App fun arg) args = analyse fun (arg:args)
    analyse fun@(Lam {})  args = beta fun [] args 

    analyse (Var fun) args
	| Just con <- isDataConWorkId_maybe fun
        , count isValArg args == idArity fun
	, let (univ_ty_args, rest_args) = splitAtList (dataConUnivTyVars con) args
	= Just (con, stripTypeArgs univ_ty_args, rest_args)

	-- Look through dictionary functions; see Note [Unfolding DFuns]
        | DFunUnfolding dfun_nargs con ops <- unfolding
        , let sat = length args == dfun_nargs    -- See Note [DFun arity check]
          in if sat then True else 
             pprTrace "Unsaturated dfun" (ppr fun <+> int dfun_nargs $$ ppr args) False   
        , let (dfun_tvs, _n_theta, _cls, dfun_res_tys) = tcSplitDFunTy (idType fun)
              subst    = zipOpenTvSubst dfun_tvs (stripTypeArgs (takeList dfun_tvs args))
              mk_arg (DFunConstArg e) = e
              mk_arg (DFunLamArg i)   = args !! i
              mk_arg (DFunPolyArg e)  = mkApps e args
        = Just (con, substTys subst dfun_res_tys, map mk_arg ops)

	-- Look through unfoldings, but only cheap ones, because
	-- we are effectively duplicating the unfolding
	| Just rhs <- expandUnfolding_maybe unfolding
	= -- pprTrace "expanding" (ppr fun $$ ppr rhs) $
          analyse rhs args
        where
	  unfolding = id_unf fun

    analyse _ _ = Nothing

    -----------
    beta (Lam v body) pairs (arg : args) 
        | isTyCoArg arg
        = beta body ((v,arg):pairs) args 

    beta (Lam {}) _ _    -- Un-saturated, or not a type lambda
	= Nothing

    beta fun pairs args
        = analyse (substExpr (text "subst-expr-is-con-app") subst fun) args
        where
          subst = mkOpenSubst (mkInScopeSet (exprFreeVars fun)) pairs
	  -- doc = vcat [ppr fun, ppr expr, ppr pairs, ppr args]

stripTypeArgs :: [CoreExpr] -> [Type]
stripTypeArgs args = ASSERT2( all isTypeArg args, ppr args )
                     [ty | Type ty <- args]
  -- We really do want isTypeArg here, not isTyCoArg!
\end{code}

Note [Unfolding DFuns]
~~~~~~~~~~~~~~~~~~~~~~
DFuns look like

  df :: forall a b. (Eq a, Eq b) -> Eq (a,b)
  df a b d_a d_b = MkEqD (a,b) ($c1 a b d_a d_b)
                               ($c2 a b d_a d_b)

So to split it up we just need to apply the ops $c1, $c2 etc
to the very same args as the dfun.  It takes a little more work
to compute the type arguments to the dictionary constructor.

Note [DFun arity check]
~~~~~~~~~~~~~~~~~~~~~~~
Here we check that the total number of supplied arguments (inclding 
type args) matches what the dfun is expecting.  This may be *less*
than the ordinary arity of the dfun: see Note [DFun unfoldings] in CoreSyn
