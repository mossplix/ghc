%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section{Monadic type operations}

This module contains monadic operations over types that contain mutable type variables

\begin{code}
module TcMType (
  TcTyVar, TcKind, TcType, TcTauType, TcThetaType, TcTyVarSet,

  --------------------------------
  -- Creating new mutable type variables
  newTyVar, newSigTyVar,
  newTyVarTy,		-- Kind -> TcM TcType
  newTyVarTys,		-- Int -> Kind -> TcM [TcType]
  newKindVar, newKindVars, 
  putTcTyVar, getTcTyVar,
  newMutTyVar, readMutTyVar, writeMutTyVar, 

  --------------------------------
  -- Instantiation
  tcInstTyVar, tcInstTyVars, tcInstType, 

  --------------------------------
  -- Checking type validity
  Rank, UserTypeCtxt(..), checkValidType, pprHsSigCtxt,
  SourceTyCtxt(..), checkValidTheta, checkFreeness,
  checkValidInstHead, instTypeErr, checkAmbiguity,
  arityErr, 

  --------------------------------
  -- Zonking
  zonkType,
  zonkTcTyVar, zonkTcTyVars, zonkTcTyVarsAndFV, 
  zonkTcType, zonkTcTypes, zonkTcClassConstraints, zonkTcThetaType,
  zonkTcPredType, zonkTcTyVarToTyVar, 
  zonkTcKindToKind, zonkTcKind,

  readKindVar, writeKindVar

  ) where

#include "HsVersions.h"


-- friends:
import HsSyn		( LHsType )
import TypeRep		( Type(..), PredType(..), TyNote(..),	 -- Friend; can see representation
			  Kind, ThetaType
			) 
import TcType		( TcType, TcThetaType, TcTauType, TcPredType,
			  TcTyVarSet, TcKind, TcTyVar, TyVarDetails(..),
			  tcEqType, tcCmpPred, isClassPred, 
			  tcSplitPhiTy, tcSplitPredTy_maybe, tcSplitAppTy_maybe, 
			  tcSplitTyConApp_maybe, tcSplitForAllTys,
			  tcIsTyVarTy, tcSplitSigmaTy, tcIsTyVarTy,
			  isUnLiftedType, isIPPred, 
			  typeKind,
			  mkAppTy, mkTyVarTy, mkTyVarTys, 
			  tyVarsOfPred, getClassPredTys_maybe,
			  tyVarsOfType, tyVarsOfTypes, 
			  pprPred, pprTheta, pprClassPred )
import Kind		( Kind(..), KindVar(..), mkKindVar,
			  isLiftedTypeKind, isArgTypeKind, isOpenTypeKind,
			  liftedTypeKind
			)
import Subst		( Subst, mkTopTyVarSubst, substTy )
import Class		( Class, classArity, className )
import TyCon		( TyCon, isSynTyCon, isUnboxedTupleTyCon, 
			  tyConArity, tyConName )
import Var		( TyVar, tyVarKind, tyVarName, isTyVar, 
			  mkTyVar, mkTcTyVar, tcTyVarRef, isTcTyVar )

-- others:
import TcRnMonad          -- TcType, amongst others
import FunDeps		( grow )
import Name		( Name, setNameUnique, mkSysTvName )
import VarSet
import CmdLineOpts	( dopt, DynFlag(..) )
import Util		( nOfThem, isSingleton, equalLength, notNull )
import ListSetOps	( removeDups )
import SrcLoc		( unLoc )
import Outputable
\end{code}


%************************************************************************
%*									*
\subsection{New type variables}
%*									*
%************************************************************************

\begin{code}
newMutTyVar :: Name -> Kind -> TyVarDetails -> TcM TyVar
newMutTyVar name kind details
  = do { ref <- newMutVar Nothing ;
	 return (mkTcTyVar name kind details ref) }

readMutTyVar :: TyVar -> TcM (Maybe Type)
readMutTyVar tyvar = readMutVar (tcTyVarRef tyvar)

writeMutTyVar :: TyVar -> Maybe Type -> TcM ()
writeMutTyVar tyvar val = writeMutVar (tcTyVarRef tyvar) val

newTyVar :: Kind -> TcM TcTyVar
newTyVar kind
  = newUnique 	`thenM` \ uniq ->
    newMutTyVar (mkSysTvName uniq FSLIT("t")) kind VanillaTv

newSigTyVar :: Kind -> TcM TcTyVar
newSigTyVar kind
  = newUnique 	`thenM` \ uniq ->
    newMutTyVar (mkSysTvName uniq FSLIT("s")) kind SigTv

newTyVarTy  :: Kind -> TcM TcType
newTyVarTy kind
  = newTyVar kind	`thenM` \ tc_tyvar ->
    returnM (TyVarTy tc_tyvar)

newTyVarTys :: Int -> Kind -> TcM [TcType]
newTyVarTys n kind = mappM newTyVarTy (nOfThem n kind)

newKindVar :: TcM TcKind
newKindVar = do	{ uniq <- newUnique
		; ref <- newMutVar Nothing
		; return (KindVar (mkKindVar uniq ref)) }

newKindVars :: Int -> TcM [TcKind]
newKindVars n = mappM (\ _ -> newKindVar) (nOfThem n ())
\end{code}


%************************************************************************
%*									*
\subsection{Type instantiation}
%*									*
%************************************************************************

Instantiating a bunch of type variables

\begin{code}
tcInstTyVars :: TyVarDetails -> [TyVar] 
	     -> TcM ([TcTyVar], [TcType], Subst)

tcInstTyVars tv_details tyvars
  = mappM (tcInstTyVar tv_details) tyvars	`thenM` \ tc_tyvars ->
    let
	tys = mkTyVarTys tc_tyvars
    in
    returnM (tc_tyvars, tys, mkTopTyVarSubst tyvars tys)
		-- Since the tyvars are freshly made,
		-- they cannot possibly be captured by
		-- any existing for-alls.  Hence mkTopTyVarSubst

tcInstTyVar tv_details tyvar
  = newUnique 		`thenM` \ uniq ->
    let
	name = setNameUnique (tyVarName tyvar) uniq
	-- Note that we don't change the print-name
	-- This won't confuse the type checker but there's a chance
	-- that two different tyvars will print the same way 
	-- in an error message.  -dppr-debug will show up the difference
	-- Better watch out for this.  If worst comes to worst, just
	-- use mkSystemName.
    in
    newMutTyVar name (tyVarKind tyvar) tv_details

tcInstType :: TyVarDetails -> TcType -> TcM ([TcTyVar], TcThetaType, TcType)
-- tcInstType instantiates the outer-level for-alls of a TcType with
-- fresh (mutable) type variables, splits off the dictionary part, 
-- and returns the pieces.
tcInstType tv_details ty
  = case tcSplitForAllTys ty of
	([],     rho) -> 	-- There may be overloading despite no type variables;
				-- 	(?x :: Int) => Int -> Int
			 let
			   (theta, tau) = tcSplitPhiTy rho
			 in
			 returnM ([], theta, tau)

	(tyvars, rho) -> tcInstTyVars tv_details tyvars		`thenM` \ (tyvars', _, tenv) ->
			 let
			   (theta, tau) = tcSplitPhiTy (substTy tenv rho)
			 in
			 returnM (tyvars', theta, tau)
\end{code}


%************************************************************************
%*									*
\subsection{Putting and getting  mutable type variables}
%*									*
%************************************************************************

\begin{code}
putTcTyVar :: TcTyVar -> TcType -> TcM TcType
getTcTyVar :: TcTyVar -> TcM (Maybe TcType)
\end{code}

Putting is easy:

\begin{code}
putTcTyVar tyvar ty 
  | not (isTcTyVar tyvar)
  = pprTrace "putTcTyVar" (ppr tyvar) $
    returnM ty

  | otherwise
  = ASSERT( isTcTyVar tyvar )
    writeMutTyVar tyvar (Just ty)	`thenM_`
    returnM ty
\end{code}

Getting is more interesting.  The easy thing to do is just to read, thus:

\begin{verbatim}
getTcTyVar tyvar = readMutTyVar tyvar
\end{verbatim}

But it's more fun to short out indirections on the way: If this
version returns a TyVar, then that TyVar is unbound.  If it returns
any other type, then there might be bound TyVars embedded inside it.

We return Nothing iff the original box was unbound.

\begin{code}
getTcTyVar tyvar
  | not (isTcTyVar tyvar)
  = pprTrace "getTcTyVar" (ppr tyvar) $
    returnM (Just (mkTyVarTy tyvar))

  | otherwise
  = ASSERT2( isTcTyVar tyvar, ppr tyvar )
    readMutTyVar tyvar				`thenM` \ maybe_ty ->
    case maybe_ty of
	Just ty -> short_out ty				`thenM` \ ty' ->
		   writeMutTyVar tyvar (Just ty')	`thenM_`
		   returnM (Just ty')

	Nothing	   -> returnM Nothing

short_out :: TcType -> TcM TcType
short_out ty@(TyVarTy tyvar)
  | not (isTcTyVar tyvar)
  = returnM ty

  | otherwise
  = readMutTyVar tyvar	`thenM` \ maybe_ty ->
    case maybe_ty of
	Just ty' -> short_out ty' 			`thenM` \ ty' ->
		    writeMutTyVar tyvar (Just ty')	`thenM_`
		    returnM ty'

	other    -> returnM ty

short_out other_ty = returnM other_ty
\end{code}


%************************************************************************
%*									*
\subsection{Zonking -- the exernal interfaces}
%*									*
%************************************************************************

-----------------  Type variables

\begin{code}
zonkTcTyVars :: [TcTyVar] -> TcM [TcType]
zonkTcTyVars tyvars = mappM zonkTcTyVar tyvars

zonkTcTyVarsAndFV :: [TcTyVar] -> TcM TcTyVarSet
zonkTcTyVarsAndFV tyvars = mappM zonkTcTyVar tyvars	`thenM` \ tys ->
			   returnM (tyVarsOfTypes tys)

zonkTcTyVar :: TcTyVar -> TcM TcType
zonkTcTyVar tyvar = zonkTyVar (\ tv -> returnM (TyVarTy tv)) tyvar
\end{code}

-----------------  Types

\begin{code}
zonkTcType :: TcType -> TcM TcType
zonkTcType ty = zonkType (\ tv -> returnM (TyVarTy tv)) ty

zonkTcTypes :: [TcType] -> TcM [TcType]
zonkTcTypes tys = mappM zonkTcType tys

zonkTcClassConstraints cts = mappM zonk cts
    where zonk (clas, tys)
	    = zonkTcTypes tys	`thenM` \ new_tys ->
	      returnM (clas, new_tys)

zonkTcThetaType :: TcThetaType -> TcM TcThetaType
zonkTcThetaType theta = mappM zonkTcPredType theta

zonkTcPredType :: TcPredType -> TcM TcPredType
zonkTcPredType (ClassP c ts)
  = zonkTcTypes ts	`thenM` \ new_ts ->
    returnM (ClassP c new_ts)
zonkTcPredType (IParam n t)
  = zonkTcType t	`thenM` \ new_t ->
    returnM (IParam n new_t)
\end{code}

-------------------  These ...ToType, ...ToKind versions
		     are used at the end of type checking

\begin{code}
-- zonkTcTyVarToTyVar is applied to the *binding* occurrence 
-- of a type variable, at the *end* of type checking.  It changes
-- the *mutable* type variable into an *immutable* one.
-- 
-- It does this by making an immutable version of tv and binds tv to it.
-- Now any bound occurences of the original type variable will get 
-- zonked to the immutable version.

zonkTcTyVarToTyVar :: TcTyVar -> TcM TyVar
zonkTcTyVarToTyVar tv
  = let
		-- Make an immutable version, defaulting 
		-- the kind to lifted if necessary
	immut_tv    = mkTyVar (tyVarName tv) (tyVarKind tv)
		-- was: defaultKind (tyVarKind tv), but I don't 
	immut_tv_ty = mkTyVarTy immut_tv

        zap tv = putTcTyVar tv immut_tv_ty
		-- Bind the mutable version to the immutable one
    in 
	-- If the type variable is mutable, then bind it to immut_tv_ty
	-- so that all other occurrences of the tyvar will get zapped too
    zonkTyVar zap tv		`thenM` \ ty2 ->

	-- This warning shows up if the allegedly-unbound tyvar is
	-- already bound to something.  It can actually happen, and 
	-- in a harmless way (see [Silly Type Synonyms] below) so
	-- it's only a warning
    WARN( not (immut_tv_ty `tcEqType` ty2), ppr tv $$ ppr immut_tv $$ ppr ty2 )

    returnM immut_tv
\end{code}

[Silly Type Synonyms]

Consider this:
	type C u a = u	-- Note 'a' unused

	foo :: (forall a. C u a -> C u a) -> u
	foo x = ...

	bar :: Num u => u
	bar = foo (\t -> t + t)

* From the (\t -> t+t) we get type  {Num d} =>  d -> d
  where d is fresh.

* Now unify with type of foo's arg, and we get:
	{Num (C d a)} =>  C d a -> C d a
  where a is fresh.

* Now abstract over the 'a', but float out the Num (C d a) constraint
  because it does not 'really' mention a.  (see Type.tyVarsOfType)
  The arg to foo becomes
	/\a -> \t -> t+t

* So we get a dict binding for Num (C d a), which is zonked to give
	a = ()

* Then the /\a abstraction has a zonked 'a' in it.

All very silly.   I think its harmless to ignore the problem.


%************************************************************************
%*									*
\subsection{Zonking -- the main work-horses: zonkType, zonkTyVar}
%*									*
%*		For internal use only!					*
%*									*
%************************************************************************

\begin{code}
-- For unbound, mutable tyvars, zonkType uses the function given to it
-- For tyvars bound at a for-all, zonkType zonks them to an immutable
--	type variable and zonks the kind too

zonkType :: (TcTyVar -> TcM Type) 	-- What to do with unbound mutable type variables
					-- see zonkTcType, and zonkTcTypeToType
	 -> TcType
	 -> TcM Type
zonkType unbound_var_fn ty
  = go ty
  where
    go (TyConApp tycon tys)	  = mappM go tys	`thenM` \ tys' ->
				    returnM (TyConApp tycon tys')

    go (NewTcApp tycon tys)	  = mappM go tys	`thenM` \ tys' ->
				    returnM (NewTcApp tycon tys')

    go (NoteTy (SynNote ty1) ty2) = go ty1		`thenM` \ ty1' ->
				    go ty2		`thenM` \ ty2' ->
				    returnM (NoteTy (SynNote ty1') ty2')

    go (NoteTy (FTVNote _) ty2)   = go ty2	-- Discard free-tyvar annotations

    go (PredTy p)		  = go_pred p		`thenM` \ p' ->
				    returnM (PredTy p')

    go (FunTy arg res)      	  = go arg		`thenM` \ arg' ->
				    go res		`thenM` \ res' ->
				    returnM (FunTy arg' res')
 
    go (AppTy fun arg)	 	  = go fun		`thenM` \ fun' ->
				    go arg		`thenM` \ arg' ->
				    returnM (mkAppTy fun' arg')
		-- NB the mkAppTy; we might have instantiated a
		-- type variable to a type constructor, so we need
		-- to pull the TyConApp to the top.

	-- The two interesting cases!
    go (TyVarTy tyvar)     = zonkTyVar unbound_var_fn tyvar

    go (ForAllTy tyvar ty) = zonkTcTyVarToTyVar tyvar	`thenM` \ tyvar' ->
			     go ty			`thenM` \ ty' ->
			     returnM (ForAllTy tyvar' ty')

    go_pred (ClassP c tys) = mappM go tys	`thenM` \ tys' ->
			     returnM (ClassP c tys')
    go_pred (IParam n ty)  = go ty		`thenM` \ ty' ->
			     returnM (IParam n ty')

zonkTyVar :: (TcTyVar -> TcM Type)		-- What to do for an unbound mutable variable
	  -> TcTyVar -> TcM TcType
zonkTyVar unbound_var_fn tyvar 
  | not (isTcTyVar tyvar)	-- Not a mutable tyvar.  This can happen when
				-- zonking a forall type, when the bound type variable
				-- needn't be mutable
  = ASSERT( isTyVar tyvar )		-- Should not be any immutable kind vars
    returnM (TyVarTy tyvar)

  | otherwise
  =  getTcTyVar tyvar	`thenM` \ maybe_ty ->
     case maybe_ty of
	  Nothing	-> unbound_var_fn tyvar			-- Mutable and unbound
	  Just other_ty	-> zonkType unbound_var_fn other_ty	-- Bound
\end{code}



%************************************************************************
%*									*
			Zonking kinds
%*									*
%************************************************************************

\begin{code}
readKindVar  :: KindVar -> TcM (Maybe TcKind)
writeKindVar :: KindVar -> TcKind -> TcM ()
readKindVar  (KVar _ ref)     = readMutVar ref
writeKindVar (KVar _ ref) val = writeMutVar ref (Just val)

-------------
zonkTcKind :: TcKind -> TcM TcKind
zonkTcKind (FunKind k1 k2) = do { k1' <- zonkTcKind k1
				; k2' <- zonkTcKind k2
				; returnM (FunKind k1' k2') }
zonkTcKind k@(KindVar kv) = do { mb_kind <- readKindVar kv 
			       ; case mb_kind of
				    Nothing -> returnM k
				    Just k  -> zonkTcKind k }
zonkTcKind other_kind = returnM other_kind

-------------
zonkTcKindToKind :: TcKind -> TcM Kind
zonkTcKindToKind (FunKind k1 k2) = do { k1' <- zonkTcKindToKind k1
				      ; k2' <- zonkTcKindToKind k2
				      ; returnM (FunKind k1' k2') }

zonkTcKindToKind (KindVar kv) = do { mb_kind <- readKindVar kv 
				   ; case mb_kind of
				       Nothing -> return liftedTypeKind
				       Just k  -> zonkTcKindToKind k }

zonkTcKindToKind OpenTypeKind = returnM liftedTypeKind	-- An "Open" kind defaults to *
zonkTcKindToKind other_kind   = returnM other_kind
\end{code}
			
%************************************************************************
%*									*
\subsection{Checking a user type}
%*									*
%************************************************************************

When dealing with a user-written type, we first translate it from an HsType
to a Type, performing kind checking, and then check various things that should 
be true about it.  We don't want to perform these checks at the same time
as the initial translation because (a) they are unnecessary for interface-file
types and (b) when checking a mutually recursive group of type and class decls,
we can't "look" at the tycons/classes yet.  Also, the checks are are rather
diverse, and used to really mess up the other code.

One thing we check for is 'rank'.  

	Rank 0: 	monotypes (no foralls)
	Rank 1:		foralls at the front only, Rank 0 inside
	Rank 2:		foralls at the front, Rank 1 on left of fn arrow,

	basic ::= tyvar | T basic ... basic

	r2  ::= forall tvs. cxt => r2a
	r2a ::= r1 -> r2a | basic
	r1  ::= forall tvs. cxt => r0
	r0  ::= r0 -> r0 | basic
	
Another thing is to check that type synonyms are saturated. 
This might not necessarily show up in kind checking.
	type A i = i
	data T k = MkT (k Int)
	f :: T A	-- BAD!

	
\begin{code}
data UserTypeCtxt 
  = FunSigCtxt Name	-- Function type signature
  | ExprSigCtxt		-- Expression type signature
  | ConArgCtxt Name	-- Data constructor argument
  | TySynCtxt Name	-- RHS of a type synonym decl
  | GenPatCtxt		-- Pattern in generic decl
			-- 	f{| a+b |} (Inl x) = ...
  | PatSigCtxt		-- Type sig in pattern
			-- 	f (x::t) = ...
  | ResSigCtxt		-- Result type sig
			-- 	f x :: t = ....
  | ForSigCtxt Name	-- Foreign inport or export signature
  | RuleSigCtxt Name 	-- Signature on a forall'd variable in a RULE
  | DefaultDeclCtxt	-- Types in a default declaration

-- Notes re TySynCtxt
-- We allow type synonyms that aren't types; e.g.  type List = []
--
-- If the RHS mentions tyvars that aren't in scope, we'll 
-- quantify over them:
--	e.g. 	type T = a->a
-- will become	type T = forall a. a->a
--
-- With gla-exts that's right, but for H98 we should complain. 


pprHsSigCtxt :: UserTypeCtxt -> LHsType Name -> SDoc
pprHsSigCtxt ctxt hs_ty = pprUserTypeCtxt (unLoc hs_ty) ctxt

pprUserTypeCtxt ty (FunSigCtxt n)  = sep [ptext SLIT("In the type signature:"), pp_sig n ty]
pprUserTypeCtxt ty ExprSigCtxt     = sep [ptext SLIT("In an expression type signature:"), nest 2 (ppr ty)]
pprUserTypeCtxt ty (ConArgCtxt c)  = sep [ptext SLIT("In the type of the constructor"), pp_sig c ty]
pprUserTypeCtxt ty (TySynCtxt c)   = sep [ptext SLIT("In the RHS of the type synonym") <+> quotes (ppr c) <> comma,
				          nest 2 (ptext SLIT(", namely") <+> ppr ty)]
pprUserTypeCtxt ty GenPatCtxt      = sep [ptext SLIT("In the type pattern of a generic definition:"), nest 2 (ppr ty)]
pprUserTypeCtxt ty PatSigCtxt      = sep [ptext SLIT("In a pattern type signature:"), nest 2 (ppr ty)]
pprUserTypeCtxt ty ResSigCtxt      = sep [ptext SLIT("In a result type signature:"), nest 2 (ppr ty)]
pprUserTypeCtxt ty (ForSigCtxt n)  = sep [ptext SLIT("In the foreign declaration:"), pp_sig n ty]
pprUserTypeCtxt ty (RuleSigCtxt n) = sep [ptext SLIT("In the type signature:"), pp_sig n ty]
pprUserTypeCtxt ty DefaultDeclCtxt = sep [ptext SLIT("In a type in a `default' declaration:"), nest 2 (ppr ty)]

pp_sig n ty = nest 2 (ppr n <+> dcolon <+> ppr ty)
\end{code}

\begin{code}
checkValidType :: UserTypeCtxt -> Type -> TcM ()
-- Checks that the type is valid for the given context
checkValidType ctxt ty
  = traceTc (text "checkValidType" <+> ppr ty)	`thenM_`
    doptM Opt_GlasgowExts	`thenM` \ gla_exts ->
    let 
	rank | gla_exts = Arbitrary
	     | otherwise
	     = case ctxt of	-- Haskell 98
		 GenPatCtxt	-> Rank 0
		 PatSigCtxt	-> Rank 0
		 DefaultDeclCtxt-> Rank 0
		 ResSigCtxt	-> Rank 0
		 TySynCtxt _    -> Rank 0
		 ExprSigCtxt 	-> Rank 1
		 FunSigCtxt _   -> Rank 1
		 ConArgCtxt _   -> Rank 1	-- We are given the type of the entire
						-- constructor, hence rank 1
		 ForSigCtxt _	-> Rank 1
		 RuleSigCtxt _	-> Rank 1

	actual_kind = typeKind ty

	kind_ok = case ctxt of
			TySynCtxt _  -> True	-- Any kind will do
			ResSigCtxt   -> isOpenTypeKind 	 actual_kind
			ExprSigCtxt  -> isOpenTypeKind 	 actual_kind
			GenPatCtxt   -> isLiftedTypeKind actual_kind
			ForSigCtxt _ -> isLiftedTypeKind actual_kind
			other	     -> isArgTypeKind       actual_kind
	
	ubx_tup | not gla_exts = UT_NotOk
		| otherwise    = case ctxt of
				   TySynCtxt _ -> UT_Ok
				   ExprSigCtxt -> UT_Ok
				   other       -> UT_NotOk
		-- Unboxed tuples ok in function results,
		-- but for type synonyms we allow them even at
		-- top level
    in
	-- Check that the thing has kind Type, and is lifted if necessary
    checkTc kind_ok (kindErr actual_kind)	`thenM_`

	-- Check the internal validity of the type itself
    check_poly_type rank ubx_tup ty		`thenM_`

    traceTc (text "checkValidType done" <+> ppr ty)
\end{code}


\begin{code}
data Rank = Rank Int | Arbitrary

decRank :: Rank -> Rank
decRank Arbitrary = Arbitrary
decRank (Rank n)  = Rank (n-1)

----------------------------------------
data UbxTupFlag = UT_Ok	| UT_NotOk
	-- The "Ok" version means "ok if -fglasgow-exts is on"

----------------------------------------
check_poly_type :: Rank -> UbxTupFlag -> Type -> TcM ()
check_poly_type (Rank 0) ubx_tup ty 
  = check_tau_type (Rank 0) ubx_tup ty

check_poly_type rank ubx_tup ty 
  = let
	(tvs, theta, tau) = tcSplitSigmaTy ty
    in
    check_valid_theta SigmaCtxt theta		`thenM_`
    check_tau_type (decRank rank) ubx_tup tau 	`thenM_`
    checkFreeness tvs theta			`thenM_`
    checkAmbiguity tvs theta (tyVarsOfType tau)

----------------------------------------
check_arg_type :: Type -> TcM ()
-- The sort of type that can instantiate a type variable,
-- or be the argument of a type constructor.
-- Not an unboxed tuple, not a forall.
-- Other unboxed types are very occasionally allowed as type
-- arguments depending on the kind of the type constructor
-- 
-- For example, we want to reject things like:
--
--	instance Ord a => Ord (forall s. T s a)
-- and
--	g :: T s (forall b.b)
--
-- NB: unboxed tuples can have polymorphic or unboxed args.
--     This happens in the workers for functions returning
--     product types with polymorphic components.
--     But not in user code.
-- Anyway, they are dealt with by a special case in check_tau_type

check_arg_type ty 
  = check_tau_type (Rank 0) UT_NotOk ty		`thenM_` 
    checkTc (not (isUnLiftedType ty)) (unliftedArgErr ty)

----------------------------------------
check_tau_type :: Rank -> UbxTupFlag -> Type -> TcM ()
-- Rank is allowed rank for function args
-- No foralls otherwise

check_tau_type rank ubx_tup ty@(ForAllTy _ _) = failWithTc (forAllTyErr ty)
check_tau_type rank ubx_tup (PredTy sty)    = getDOpts		`thenM` \ dflags ->
						check_source_ty dflags TypeCtxt sty
check_tau_type rank ubx_tup (TyVarTy _)       = returnM ()
check_tau_type rank ubx_tup ty@(FunTy arg_ty res_ty)
  = check_poly_type rank UT_NotOk arg_ty	`thenM_`
    check_tau_type  rank UT_Ok    res_ty

check_tau_type rank ubx_tup (AppTy ty1 ty2)
  = check_arg_type ty1 `thenM_` check_arg_type ty2

check_tau_type rank ubx_tup (NoteTy (SynNote syn) ty)
	-- Synonym notes are built only when the synonym is 
	-- saturated (see Type.mkSynTy)
  = doptM Opt_GlasgowExts			`thenM` \ gla_exts ->
    (if gla_exts then
	-- If -fglasgow-exts then don't check the 'note' part.
	-- This  allows us to instantiate a synonym defn with a 
	-- for-all type, or with a partially-applied type synonym.
	-- 	e.g.   type T a b = a
	--	       type S m   = m ()
	--	       f :: S (T Int)
	-- Here, T is partially applied, so it's illegal in H98.
	-- But if you expand S first, then T we get just 
	--	       f :: Int
	-- which is fine.
	returnM ()
    else
	-- For H98, do check the un-expanded part
	check_tau_type rank ubx_tup syn		
    )						`thenM_`

    check_tau_type rank ubx_tup ty

check_tau_type rank ubx_tup (NoteTy other_note ty)
  = check_tau_type rank ubx_tup ty

check_tau_type rank ubx_tup (NewTcApp tc tys)
  = mappM_ check_arg_type tys

check_tau_type rank ubx_tup ty@(TyConApp tc tys)
  | isSynTyCon tc	
  = 	-- NB: Type.mkSynTy builds a TyConApp (not a NoteTy) for an unsaturated
	-- synonym application, leaving it to checkValidType (i.e. right here)
	-- to find the error
    checkTc syn_arity_ok arity_msg	`thenM_`
    mappM_ check_arg_type tys
    
  | isUnboxedTupleTyCon tc
  = doptM Opt_GlasgowExts			`thenM` \ gla_exts ->
    checkTc (ubx_tup_ok gla_exts) ubx_tup_msg	`thenM_`
    mappM_ (check_tau_type (Rank 0) UT_Ok) tys	
		-- Args are allowed to be unlifted, or
		-- more unboxed tuples, so can't use check_arg_ty

  | otherwise
  = mappM_ check_arg_type tys

  where
    ubx_tup_ok gla_exts = case ubx_tup of { UT_Ok -> gla_exts; other -> False }

    syn_arity_ok = tc_arity <= n_args
		-- It's OK to have an *over-applied* type synonym
		--	data Tree a b = ...
		--	type Foo a = Tree [a]
		--	f :: Foo a b -> ...
    n_args    = length tys
    tc_arity  = tyConArity tc

    arity_msg   = arityErr "Type synonym" (tyConName tc) tc_arity n_args
    ubx_tup_msg = ubxArgTyErr ty

----------------------------------------
forAllTyErr     ty = ptext SLIT("Illegal polymorphic type:") <+> ppr ty
unliftedArgErr  ty = ptext SLIT("Illegal unlifted type argument:") <+> ppr ty
ubxArgTyErr     ty = ptext SLIT("Illegal unboxed tuple type as function argument:") <+> ppr ty
kindErr kind       = ptext SLIT("Expecting an ordinary type, but found a type of kind") <+> ppr kind
\end{code}



%************************************************************************
%*									*
\subsection{Checking a theta or source type}
%*									*
%************************************************************************

\begin{code}
-- Enumerate the contexts in which a "source type", <S>, can occur
--	Eq a 
-- or 	?x::Int
-- or 	r <: {x::Int}
-- or 	(N a) where N is a newtype

data SourceTyCtxt
  = ClassSCCtxt Name	-- Superclasses of clas
			-- 	class <S> => C a where ...
  | SigmaCtxt		-- Theta part of a normal for-all type
			--	f :: <S> => a -> a
  | DataTyCtxt Name	-- Theta part of a data decl
			--	data <S> => T a = MkT a
  | TypeCtxt 		-- Source type in an ordinary type
			-- 	f :: N a -> N a
  | InstThetaCtxt	-- Context of an instance decl
			--	instance <S> => C [a] where ...
  | InstHeadCtxt	-- Head of an instance decl
			-- 	instance ... => Eq a where ...
		
pprSourceTyCtxt (ClassSCCtxt c) = ptext SLIT("the super-classes of class") <+> quotes (ppr c)
pprSourceTyCtxt SigmaCtxt       = ptext SLIT("the context of a polymorphic type")
pprSourceTyCtxt (DataTyCtxt tc) = ptext SLIT("the context of the data type declaration for") <+> quotes (ppr tc)
pprSourceTyCtxt InstThetaCtxt   = ptext SLIT("the context of an instance declaration")
pprSourceTyCtxt InstHeadCtxt    = ptext SLIT("the head of an instance declaration")
pprSourceTyCtxt TypeCtxt        = ptext SLIT("the context of a type")
\end{code}

\begin{code}
checkValidTheta :: SourceTyCtxt -> ThetaType -> TcM ()
checkValidTheta ctxt theta 
  = addErrCtxt (checkThetaCtxt ctxt theta) (check_valid_theta ctxt theta)

-------------------------
check_valid_theta ctxt []
  = returnM ()
check_valid_theta ctxt theta
  = getDOpts					`thenM` \ dflags ->
    warnTc (notNull dups) (dupPredWarn dups)	`thenM_`
	-- Actually, in instance decls and type signatures, 
	-- duplicate constraints are eliminated by TcHsType.hoistForAllTys,
	-- so this error can only fire for the context of a class or
	-- data type decl.
    mappM_ (check_source_ty dflags ctxt) theta
  where
    (_,dups) = removeDups tcCmpPred theta

-------------------------
check_source_ty dflags ctxt pred@(ClassP cls tys)
  = 	-- Class predicates are valid in all contexts
    checkTc (arity == n_tys) arity_err		`thenM_`

	-- Check the form of the argument types
    mappM_ check_arg_type tys				`thenM_`
    checkTc (check_class_pred_tys dflags ctxt tys)
	    (predTyVarErr pred $$ how_to_allow)

  where
    class_name = className cls
    arity      = classArity cls
    n_tys      = length tys
    arity_err  = arityErr "Class" class_name arity n_tys

    how_to_allow = case ctxt of
		     InstHeadCtxt  -> empty	-- Should not happen
		     InstThetaCtxt -> parens undecidableMsg
		     other	   -> parens (ptext SLIT("Use -fglasgow-exts to permit this"))

check_source_ty dflags SigmaCtxt (IParam _ ty) = check_arg_type ty
	-- Implicit parameters only allows in type
	-- signatures; not in instance decls, superclasses etc
	-- The reason for not allowing implicit params in instances is a bit subtle
	-- If we allowed	instance (?x::Int, Eq a) => Foo [a] where ...
	-- then when we saw (e :: (?x::Int) => t) it would be unclear how to 
	-- discharge all the potential usas of the ?x in e.   For example, a
	-- constraint Foo [Int] might come out of e,and applying the
	-- instance decl would show up two uses of ?x.

-- Catch-all
check_source_ty dflags ctxt sty = failWithTc (badSourceTyErr sty)

-------------------------
check_class_pred_tys dflags ctxt tys 
  = case ctxt of
	InstHeadCtxt  -> True	-- We check for instance-head 
				-- formation in checkValidInstHead
	InstThetaCtxt -> undecidable_ok || all tcIsTyVarTy tys
	other	      -> gla_exts       || all tyvar_head tys
  where
    undecidable_ok = dopt Opt_AllowUndecidableInstances dflags 
    gla_exts 	   = dopt Opt_GlasgowExts dflags

-------------------------
tyvar_head ty			-- Haskell 98 allows predicates of form 
  | tcIsTyVarTy ty = True	-- 	C (a ty1 .. tyn)
  | otherwise			-- where a is a type variable
  = case tcSplitAppTy_maybe ty of
	Just (ty, _) -> tyvar_head ty
	Nothing	     -> False
\end{code}

Check for ambiguity
~~~~~~~~~~~~~~~~~~~
	  forall V. P => tau
is ambiguous if P contains generic variables
(i.e. one of the Vs) that are not mentioned in tau

However, we need to take account of functional dependencies
when we speak of 'mentioned in tau'.  Example:
	class C a b | a -> b where ...
Then the type
	forall x y. (C x y) => x
is not ambiguous because x is mentioned and x determines y

NB; the ambiguity check is only used for *user* types, not for types
coming from inteface files.  The latter can legitimately have
ambiguous types. Example

   class S a where s :: a -> (Int,Int)
   instance S Char where s _ = (1,1)
   f:: S a => [a] -> Int -> (Int,Int)
   f (_::[a]) x = (a*x,b)
	where (a,b) = s (undefined::a)

Here the worker for f gets the type
	fw :: forall a. S a => Int -> (# Int, Int #)

If the list of tv_names is empty, we have a monotype, and then we
don't need to check for ambiguity either, because the test can't fail
(see is_ambig).

\begin{code}
checkAmbiguity :: [TyVar] -> ThetaType -> TyVarSet -> TcM ()
checkAmbiguity forall_tyvars theta tau_tyvars
  = mappM_ complain (filter is_ambig theta)
  where
    complain pred     = addErrTc (ambigErr pred)
    extended_tau_vars = grow theta tau_tyvars

	-- Only a *class* predicate can give rise to ambiguity
	-- An *implicit parameter* cannot.  For example:
	--	foo :: (?x :: [a]) => Int
	--	foo = length ?x
	-- is fine.  The call site will suppply a particular 'x'
    is_ambig pred     = isClassPred  pred &&
			any ambig_var (varSetElems (tyVarsOfPred pred))

    ambig_var ct_var  = (ct_var `elem` forall_tyvars) &&
		        not (ct_var `elemVarSet` extended_tau_vars)

ambigErr pred
  = sep [ptext SLIT("Ambiguous constraint") <+> quotes (pprPred pred),
	 nest 4 (ptext SLIT("At least one of the forall'd type variables mentioned by the constraint") $$
		 ptext SLIT("must be reachable from the type after the '=>'"))]
\end{code}
    
In addition, GHC insists that at least one type variable
in each constraint is in V.  So we disallow a type like
	forall a. Eq b => b -> b
even in a scope where b is in scope.

\begin{code}
checkFreeness forall_tyvars theta
  = mappM_ complain (filter is_free theta)
  where    
    is_free pred     =  not (isIPPred pred)
		     && not (any bound_var (varSetElems (tyVarsOfPred pred)))
    bound_var ct_var = ct_var `elem` forall_tyvars
    complain pred    = addErrTc (freeErr pred)

freeErr pred
  = sep [ptext SLIT("All of the type variables in the constraint") <+> quotes (pprPred pred) <+>
		   ptext SLIT("are already in scope"),
	 nest 4 (ptext SLIT("(at least one must be universally quantified here)"))
    ]
\end{code}

\begin{code}
checkThetaCtxt ctxt theta
  = vcat [ptext SLIT("In the context:") <+> pprTheta theta,
	  ptext SLIT("While checking") <+> pprSourceTyCtxt ctxt ]

badSourceTyErr sty = ptext SLIT("Illegal constraint") <+> pprPred sty
predTyVarErr pred  = ptext SLIT("Non-type variables in constraint:") <+> pprPred pred
dupPredWarn dups   = ptext SLIT("Duplicate constraint(s):") <+> pprWithCommas pprPred (map head dups)

arityErr kind name n m
  = hsep [ text kind, quotes (ppr name), ptext SLIT("should have"),
	   n_arguments <> comma, text "but has been given", int m]
    where
	n_arguments | n == 0 = ptext SLIT("no arguments")
		    | n == 1 = ptext SLIT("1 argument")
		    | True   = hsep [int n, ptext SLIT("arguments")]
\end{code}


%************************************************************************
%*									*
\subsection{Checking for a decent instance head type}
%*									*
%************************************************************************

@checkValidInstHead@ checks the type {\em and} its syntactic constraints:
it must normally look like: @instance Foo (Tycon a b c ...) ...@

The exceptions to this syntactic checking: (1)~if the @GlasgowExts@
flag is on, or (2)~the instance is imported (they must have been
compiled elsewhere). In these cases, we let them go through anyway.

We can also have instances for functions: @instance Foo (a -> b) ...@.

\begin{code}
checkValidInstHead :: Type -> TcM (Class, [TcType])

checkValidInstHead ty	-- Should be a source type
  = case tcSplitPredTy_maybe ty of {
	Nothing -> failWithTc (instTypeErr (ppr ty) empty) ;
	Just pred -> 

    case getClassPredTys_maybe pred of {
	Nothing -> failWithTc (instTypeErr (pprPred pred) empty) ;
        Just (clas,tys) ->

    getDOpts					`thenM` \ dflags ->
    mappM_ check_arg_type tys			`thenM_`
    check_inst_head dflags clas tys		`thenM_`
    returnM (clas, tys)
    }}

check_inst_head dflags clas tys
	-- If GlasgowExts then check at least one isn't a type variable
  | dopt Opt_GlasgowExts dflags
  = check_tyvars dflags clas tys

	-- WITH HASKELL 1.4, MUST HAVE C (T a b c)
  | isSingleton tys,
    Just (tycon, arg_tys) <- tcSplitTyConApp_maybe first_ty,
    not (isSynTyCon tycon), 		-- ...but not a synonym
    all tcIsTyVarTy arg_tys,  		-- Applied to type variables
    equalLength (varSetElems (tyVarsOfTypes arg_tys)) arg_tys
          -- This last condition checks that all the type variables are distinct
  = returnM ()

  | otherwise
  = failWithTc (instTypeErr (pprClassPred clas tys) head_shape_msg)

  where
    (first_ty : _)       = tys

    head_shape_msg = parens (text "The instance type must be of form (T a b c)" $$
			     text "where T is not a synonym, and a,b,c are distinct type variables")

check_tyvars dflags clas tys
   	-- Check that at least one isn't a type variable
	-- unless -fallow-undecideable-instances
  | dopt Opt_AllowUndecidableInstances dflags = returnM ()
  | not (all tcIsTyVarTy tys)	  	      = returnM ()
  | otherwise 				      = failWithTc (instTypeErr (pprClassPred clas tys) msg)
  where
    msg =  parens (ptext SLIT("There must be at least one non-type-variable in the instance head")
		   $$ undecidableMsg)

undecidableMsg = ptext SLIT("Use -fallow-undecidable-instances to permit this")
\end{code}

\begin{code}
instTypeErr pp_ty msg
  = sep [ptext SLIT("Illegal instance declaration for") <+> quotes pp_ty, 
	 nest 4 msg]
\end{code}
