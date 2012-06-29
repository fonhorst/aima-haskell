{-# LANGUAGE MultiParamTypeClasses, TypeSynonymInstances, FlexibleInstances, ExplicitForAll #-}

module Search where

import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.List as L
import Data.Map (Map)
import Data.Maybe (fromJust)
import Data.Ord (comparing)
import Data.Set (Set)

import Queue
import Graph (Graph)
import qualified Graph as G

-- |The type used to represent the cost associated with a particular path.
type Cost = Double

-- |Class for an abstract problem with state type s and action type a. A
--  minimal implementation consists of 'initial' and 'successor', and one
--  of 'goal' or 'goalTest'.
class Eq s => Problem p s a where
    -- | The initial state of the problem.
    initial :: p s a -> s

    -- | Given a state, return a sequence of (action, state) pairs reachable
    --   from this state. Because of lazy evaluation we only ever compute as
    --   many elements of the list as the program needs.
    successor :: p s a -> s -> [(a, s)]
    
    -- | If the problem has a unique goal state, this method should return it.
    --   The default implementation of 'goalTest' compares for equality with
    --   this state.
    goal :: p s a -> s
    goal = undefined

    -- | Return true if the state is a goal. The default method compares the
    --   state to the state specified in the implementation of 'goal'. You can
    --   override this method if checking against a single goal is not enough.
    goalTest :: p s a -> s -> Bool
    goalTest p s = s == goal p

    -- | Return the cost of a solution path that arrives at the second state
    --   from the first state, via the specified action. If the problem is such
    --   that the path doesn't matter, the function will only look at the second
    --   state. The default implementation costs 1 for every step in the path.
    costP :: p s a -> Cost -> s -> a -> s -> Cost
    costP _ c _ _ _ = c + 1

    -- | For optimization problems, each state has a value. Hill-climbing and
    --   related algorithms try to maximise this value. The default
    --  implementation always returs Nothing.
    valueP :: p s a -> s -> Maybe Double
    valueP _ = const Nothing

-- |A node in a search tree. It contains a reference to its parent (the node
--  that this is a successor of) and to the state for this node. Note that if
--  a state can be arrived at by two paths, there will be two nodes with the
--  same state. It may also include the action that got us to this state, and
--  the total path cost.
data Node s a = Node { state  :: s
                     , parent :: Maybe (Node s a)
                     , action :: Maybe a
                     , cost   :: Cost
                     , depth  :: Int
                     , value  :: Maybe Double }

instance (Show s, Show a) => Show (Node s a) where
    show (Node state _ action cost depth _) =
        "Node(state=" ++ show state ++ ",action=" ++ show action ++ 
            ",cost=" ++ show cost ++ ",depth=" ++ show depth ++ ")"

-- |A convenience constructor for root nodes (a node with no parent, no action
--  that leads to it, and zero cost.)
root :: (Problem p s a) => p s a -> s -> Node s a
root p s = Node s Nothing Nothing 0 0 (valueP p s)

-- |Create a list of paths from the root node to the node specified.
path :: Node s a -> [Node s a]
path n = case parent n of
    Nothing -> [n]
    Just n' -> n : path n'

-- |Return a list of nodes reachable from this node in the context of the
--  specified problem.
expand :: (Problem p s a) => p s a -> Node s a -> [Node s a]
expand p node = [ mkNode a s | (a,s) <- successor p (state node) ]
    where
        mkNode a s = Node s (Just node) (Just a) (c a s) (1 + depth node) v
        c      a s = costP p (cost node) (state node) a s
        v          = valueP p (state node)

----------------------------------
-- Uninformed Search Algorithms --
----------------------------------

-- |Search through the successors of a node to find a goal. The argument
--  @fringe@ should be an empty queue. We don't worry about repeated paths
--  to a state.
treeSearch :: (Problem p s a, Queue q) => q (Node s a) -> p s a -> Maybe (Node s a)
treeSearch q prob = go prob (root prob (initial prob) `push` q)
    where
        go p fringe = if empty fringe
            then Nothing
            else let (node, rest) = pop fringe
                 in if goalTest p (state node)
                    then Just node
                    else go p (expand prob node `extend` rest)

-- |Search the deepest nodes in the search tree first.
depthFirstTreeSearch :: (Problem p s a) => p s a -> Maybe (Node s a)
depthFirstTreeSearch = treeSearch []

-- |Search the shallowest nodes in the search tree first.
breadthFirstTreeSearch :: (Problem p s a) => p s a -> Maybe (Node s a)
breadthFirstTreeSearch = treeSearch (FifoQueue [])

-- |Search through the successors of a node to find a goal. The argument
--  @fringe@ should be an empty queue. If two paths reach the same state, use
--  only the best one.
graphSearch :: (Problem p s a, Queue q, Ord s) => q (Node s a) -> p s a -> Maybe (Node s a)
graphSearch q prob = go prob (root prob (initial prob) `push` q) S.empty
    where
        go p fringe closed = if empty fringe
            then Nothing
            else if goalTest p thisState
                then Just node
                else if thisState `S.member` closed
                    then go p rest  closed
                    else go p rest' closed'
            where
                (node,rest) = pop fringe
                thisState   = state node
                rest'       = expand prob node `extend` rest
                closed'     = thisState `S.insert` closed

-- |Search the deepest nodes in the graph first.
depthFirstGraphSearch :: (Problem p s a, Ord s) => p s a -> Maybe (Node s a)
depthFirstGraphSearch = graphSearch []

-- |Search the shallowest nodes in the graph first.
breadthFirstGraphSearch :: (Problem p s a, Ord s) => p s a -> Maybe (Node s a)
breadthFirstGraphSearch = graphSearch (FifoQueue [])

-- |Depth-first search with a depth limit. If the depth limit is reached we
--  return 'Cutoff', otherwise return 'Fail' (if no solution is found) or 'Ok'
--  (if a solution is found) which take the place of Nothing and Just in the
--  other search functions.
depthLimitedSearch :: (Problem p s a) => Int -> p s a -> DepthLimited (Node s a)
depthLimitedSearch lim prob = recursiveDLS (root prob $ initial prob) prob lim
    where
        recursiveDLS node p lim
            | goalTest p (state node) = Ok node
            | depth node == lim       = Cutoff
            | otherwise               = filt False $ map go (expand prob node)
            where
                go node = recursiveDLS node p lim

                filt cutoff [] = if cutoff then Cutoff else Fail
                filt cutoff (Ok node : _)    = Ok node
                filt cutoff (Fail    : rest) = filt cutoff rest
                filt cutoff (Cutoff  : rest) = filt True   rest

data DepthLimited a = Fail | Cutoff | Ok a deriving (Show)

-- |Repeatedly try depth-limited search with an increasing depth limit.
iterativeDeepeningSearch :: (Problem p s a) => p s a -> Maybe (Node s a)
iterativeDeepeningSearch prob = go 1
    where
        go lim = case depthLimitedSearch lim prob of
            Cutoff -> go (lim + 1)
            Fail   -> Nothing
            Ok n   -> Just n

---------------------------------
-- Informed (Heuristic) Search --
---------------------------------

bestFirstTreeSearch :: (Problem p s a) => (Node s a -> Double) -> p s a -> Maybe (Node s a)
bestFirstTreeSearch f = treeSearch (PQueue [] f)

bestFirstGraphSearch :: (Problem p s a, Ord s) => (Node s a -> Double) -> p s a -> Maybe (Node s a)
bestFirstGraphSearch f = graphSearch (PQueue [] f)

aStarSearch :: (Problem p s a, Ord s) => (Node s a -> Double) -> p s a -> Maybe (Node s a)
aStarSearch h = bestFirstGraphSearch (\n -> h n + cost n)

-----------------------------
-- Local Search Algorithms --
-----------------------------

-- |From the initial node, keep choosing the neighbour with the highest value,
--  stopping when no neighbour is better.
hillClimbingSearch :: (Problem p s a) => p s a -> Node s a
hillClimbingSearch prob = go (root prob $ initial prob)
    where
        go node = if value neighbour <= value node
            then node
            else go neighbour
            where
                neighbour = argMax (expand prob node) value

argMax :: (Ord b) => [a] -> (a -> b) -> a
argMax xs f = fst $ L.maximumBy (comparing snd) $ zip xs (map f xs)

--------------------
-- A test problem --
--------------------

data WP s a = WP
    { initialWP :: s
    , goalWP :: s
    , charsWP :: [a]
    , maxLen :: Int } deriving (Show)

instance Problem WP String Char where
    initial = initialWP
    goal = goalWP
    successor p s = if length s == maxLen p
        then []
        else [ (a, a:s) | a <- charsWP p ]

wp :: WP String Char
wp = WP { initialWP = "", goalWP = "abracad", charsWP = "abrcd" , maxLen = 11 }

-------------------------------
-- Graphs and Graph Problems --
-------------------------------

data GraphMap a = G
    { getGraph     :: Graph a Cost
    , getLocations :: Map a Point } deriving (Show)

type Point = (Double,Double)

mkGraphMap :: (Ord a) => [(a,[(a,Cost)])] -> [(a,Point)] -> GraphMap a
mkGraphMap conn loc = G (G.toUndirectedGraph conn) (M.fromList loc)

getNeighbors :: Ord a => a -> GraphMap a -> [(a,Cost)]
getNeighbors a (G g _) = G.getNeighbours a g

getLocation :: Ord a => a -> GraphMap a -> Point
getLocation a (G _ l) = case M.lookup a l of
    Nothing -> error "Vertex not found in graph!"
    Just pt -> pt

costFromTo :: Ord a => GraphMap a -> a -> a -> Cost
costFromTo graph a b = case lookup b (getNeighbors a graph) of
    Nothing -> 1/0
    Just c  -> c

data GraphProblem s a = GP
    { graphGP :: GraphMap s
    , initGP :: s
    , goalGP :: s } deriving (Show)

instance Ord s => Problem GraphProblem s s where
    initial = initGP
    goal = goalGP
    successor (GP g _ _) s = [ (x,x) | (x,_) <- getNeighbors s g ]
    costP (GP g _ _) c s _ s' = c + costFromTo g s s'

euclideanDist :: Point -> Point -> Double
euclideanDist (x,y) (x',y') = sqrt $ (x-x')^2 + (y-y')^2

mkHeuristic :: Ord s => GraphProblem s a -> Node s a -> Double
mkHeuristic (GP g _ goal) node = euclideanDist x y
    where
        x = getLocation (state node) g
        y = getLocation goal g

testGraph :: GraphMap Char
testGraph = mkGraphMap

    [ ('A', [('B',5), ('C',3)])
    , ('B', [('D',6)])
    , ('C', [('D',4)]) ]

    [ ('A',(0,0)), ('B',(1,1)), ('C',(1,-1)), ('D',(2,0)) ]

gp :: GraphProblem Char Char
gp = GP { graphGP = testGraph, initGP = 'A', goalGP = 'D' }
