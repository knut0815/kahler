__all__ = ['Skeleton']

from numpy import asarray, zeros, ones, empty, sqrt, arange, int8, sqrt
from scipy.sparse import csr_matrix, dia_matrix, dok_matrix, coo_matrix
from scipy.linalg._flinalg import zdet_r
from scipy.misc import factorial
from itertools import combinations
from functools import reduce
from operator import or_

from .form_utils import wedge, derham_map
from .grid_utils import stitch
from .parallel import parmapreduce, parmap
from .circumcenter cimport compute_circumcenter

from cython cimport boundscheck, wraparound, profile
from numpy cimport complex, ndarray

@profile(True)
@boundscheck(False)
@wraparound(False)
cdef complex det(ndarray[complex, ndim=2] m):
    return zdet_r(m, True)[0]

class Skeleton(_Skeleton):
    """caches the result of costly operations"""
    
    def __getattr__(self, attr):
        if attr == "sharp":
            self.compute_sharp()
            return self.sharp
        elif attr == "boundary":
            if self.dim == self.complex.complex_dimension - 1:
                self.boundary = asarray(((abs(self.exterior_derivative).sum(axis=0).getA1() % 2) == 1).nonzero()[0], dtype="uint")
            else:
                old_boundary = self.complex[self.dim + 1].boundary
                if len(old_boundary):
                    self.boundary = asarray(abs(self.exterior_derivative[old_boundary]).sum(axis=0).getA1().nonzero()[0], dtype="uint")
                else:
                    self.boundary = asarray([], dtype="uint")
            return self.boundary
        elif attr == "interior":
            self.interior = asarray(sorted(set(arange(self.num_simplices, dtype="uint")) - set(self.boundary)), dtype="uint")
            return self.interior
        elif attr in ['exterior_derivative', 'simplices', 'simplex_to_index', 'num_simplices']:
            self.compute_exterior()
            return getattr(self, attr)
        elif attr == 'unstitched':
            self.unstitched = list(parmapreduce(self.compute_unstitched, self.complex[self.dim + 1].unstitched, or_))
            return self.unstitched
        elif attr == 'points':
            self.points = self.complex.vertices[asarray(self.unstitched)]
            return self.points
        elif attr == 'metrics':
            self.metrics = derham_map(self.complex.metric, self.points, self.complex.subdivisions)
            return self.metrics
        elif attr == "primal_volumes":
            if self.dim:
                primal_volumes = parmap(lambda stuff: (self.simplex_to_index[frozenset(stitch(stuff[0], self.complex.stitches))], self.compute_primal_volumes(stuff[1], stuff[2])), zip(self.unstitched, self.points, self.metrics))
                self.primal_volumes = empty(self.num_simplices, dtype="complex")
                for index, volume in primal_volumes:
                    self.primal_volumes[index] = volume
                self.primal_volumes /= factorial(self.dim)
            else:
                self.primal_volumes = ones(self.num_simplices, dtype="complex")
            return self.primal_volumes
        elif attr == "circumcenters":
            self.circumcenters = dict(parmap(lambda stuff: (stuff[0], compute_circumcenter(stuff[1], stuff[2])), zip(self.unstitched, self.points, self.metrics)))
            return self.circumcenters
        elif attr == "dual_volumes":
            if self.dim != self.complex.complex_dimension:
                for dim in range(self.complex.complex_dimension, self.dim - 1, -1):
                    _ = self.complex[dim].circumcenters
                self.dual_volumes = parmapreduce(lambda stuff: self.compute_dual_volumes(stuff[0], stuff[1]), zip(self.complex[-1].unstitched, self.complex[-1].metrics))
                self.dual_volumes /= factorial(self.complex.complex_dimension - self.dim)
            else:
                self.dual_volumes = ones(self.num_simplices)
            return self.dual_volumes
        elif attr == "star":
            self.star = dia_matrix((self.dual_volumes / self.primal_volumes, 0), (self.num_simplices,) * 2)
            return self.star
        elif attr == "inverse_star":
            self.inverse_star = dia_matrix((1 / self.star.diagonal(), 0), (self.num_simplices,) * 2)
            return self.inverse_star
        elif attr == "codifferential":
            if self.dim:
                self.codifferential = (-1) ** self.dim * self.complex[self.dim - 1].inverse_star.dot(self.complex[self.dim - 1].exterior_derivative.T).dot(self.star)
            else:
                self.codifferential = csr_matrix((1, self.num_simplices))
            return self.codifferential
        elif attr == "laplace_beltrami":
            if self.dim < self.complex.complex_dimension:
                self.laplace_beltrami = self.complex[self.dim + 1].codifferential.dot(self.exterior_derivative)
            else:
                self.laplace_beltrami = csr_matrix((self.num_simplices,) * 2)
            return self.laplace_beltrami
        elif attr == "laplace_derham":
            self.laplace_derham = self.laplace_beltrami.copy()
            if self.dim:
                self.laplace_derham = self.laplace_derham + self.complex[self.dim - 1].exterior_derivative.dot(self.codifferential)
            return self.laplace_derham
        else:
            raise AttributeError(attr + " not found")

cdef class _Skeleton(object):
    @profile(True)
    @boundscheck(False)
    @wraparound(False)
    cpdef compute_exterior(self):
        cdef ndarray[long unsigned int, ndim=2] old_simplices = asarray(list(self.complex[self.dim + 1].simplices))
        cdef long unsigned int col, num_simplices = 0, col_max = old_simplices.shape[0]
        cdef unsigned char j, j_max = old_simplices.shape[1]
        cdef list simplex, face
        cdef frozenset sface
        cdef list indices = []
        cdef list indptr = [0]
        cdef list data = []
        cdef list simplices = [], points = []
        cdef dict simplex_to_index = {}
        for col in range(col_max):
            simplex = list(old_simplices[col])
            for j in range(j_max):
                face = simplex[:j] + simplex[j + 1:]
                sface = frozenset(face)
                if sface in simplex_to_index:
                    indices.append(simplex_to_index[sface])
                else:
                    simplex_to_index[sface] = num_simplices
                    indices.append(num_simplices)
                    simplices.append(face)
                    num_simplices += 1
                data.append(int8((-1) ** j))
            indptr.append((col + 1) * j_max)
        self.simplices = asarray(simplices, dtype="uint")
        self.exterior_derivative = csr_matrix((data, indices, indptr), (old_simplices.shape[0], self.simplices.shape[0]), dtype="int8")
        self.num_simplices = num_simplices
        self.simplex_to_index = simplex_to_index

    @profile(True)
    @boundscheck(False)
    @wraparound(False)
    cpdef compute_sharp(self):
        cdef unsigned char cdim = self.complex.complex_dimension + 1
        cdef unsigned char edim = self.complex.embedding_dimension
        cdef unsigned char dim = self.dim + 1
        cdef unsigned int step =  edim ** self.dim
        cdef ndarray[unsigned char, ndim=1] combo = empty((dim,), dtype="uint8")
        cdef ndarray[unsigned char, ndim=2] combos = asarray(list(combinations(range(cdim), dim)), dtype="uint8")
        cdef long unsigned int n, i
        cdef complex c, element
        cdef double normalize = float(factorial(cdim)) / (factorial(self.dim) * factorial(cdim - dim))
        cdef ndarray[unsigned char, ndim=1] subset_index = empty((self.dim,), dtype="uint8")
        cdef list subset_indices = [(asarray([j for j in range(dim) if j != i0], dtype="uint8"), (-1) ** i0 / normalize) for i0 in range(dim)]
        cdef ndarray[long unsigned int, ndim=2] simplices = self.complex[cdim - 1].simplices
        cdef ndarray[long unsigned int, ndim=1] simplex = empty((cdim,), dtype="uint")
        cdef ndarray[complex, ndim=3] all_barycentric_gradients = self.complex.barycentric_gradients
        cdef ndarray[complex, ndim=2] barycentric_gradients = empty((cdim, edim), dtype="complex")
        cdef ndarray[complex, ndim=2] vectors = empty((cdim, edim), dtype="complex")
        cdef list rows = [], columns = [], data = []
        
        if not self.dim:
            c = 1 / normalize
            for n_index in range(self.complex[cdim - 1].num_simplices):
                for j in range(cdim):
                    rows.append(n_index)
                    columns.append(self.simplex_to_index[frozenset(stitch((simplices[n_index, j],), self.complex.stitches))])
                    data.append(c)
            self.sharp = coo_matrix((data, (rows, columns)), (self.complex[cdim - 1].num_simplices, self.num_simplices)).tocsr()
            return
            
        sharp = dok_matrix((self.complex[cdim - 1].num_simplices * step, self.num_simplices), dtype="complex")
        for n in range(self.complex[cdim - 1].num_simplices):
            simplex = simplices[n]
            barycentric_gradients = all_barycentric_gradients[n]
            n *= step
            for combo in combos:
                vectors = barycentric_gradients[combo]
                i = self.simplex_to_index[frozenset(stitch(simplex[combo], self.complex.stitches))]
                for subset_index, c in subset_indices:
                    for j, element in enumerate(reduce(wedge, vectors[subset_index]).flat):
                        if element != 0:
                            sharp[n + j, i] += element * c
        self.sharp = sharp.tocsr()

    @profile(True)
    @boundscheck(False)
    @wraparound(False)
    cpdef compute_primal_volumes(self, ndarray[complex, ndim=2] points, ndarray[complex, ndim=2] metric):
        cdef ndarray[complex, ndim=2] vecs = points[1:] - points[0]
        return sqrt(det(vecs.dot(metric).dot(vecs.conj().T)))

    @profile(True)
    @boundscheck(False)
    @wraparound(False)
    cpdef compute_dual_volumes(self, tuple simplex, ndarray[complex, ndim=2] metric):
        cdef ndarray[complex, ndim=1] volumes = zeros((self.num_simplices,), dtype="complex")
        cdef ndarray[complex, ndim=2] points = empty((self.dim + 1, self.complex.embedding_dimension), dtype="complex")
        cdef ndarray[complex, ndim=2] vecs = empty((self.dim, self.complex.embedding_dimension), dtype="complex")
        cdef unsigned long int p_index
        cdef list dual_cell
        for dual_cell, p_index in self.complex.compute_dual_cells(simplex, self.dim):
            points = asarray(dual_cell)
            vecs = points[1:] - points[0]
            volumes[p_index] = volumes[p_index] + sqrt(det(vecs.dot(metric).dot(vecs.conj().T)))
        return volumes

    cpdef set compute_unstitched(self, tuple simplex):
        cdef unsigned char i
        cdef res = set([])
        for i in range(len(simplex)):
            res.add(simplex[:i] + simplex[i + 1:])
        return res