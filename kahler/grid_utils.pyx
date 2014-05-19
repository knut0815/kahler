__all__ = ['stitch', 'embed', 'grid', 'pbc_stitches', 'grid_indices', 'symmetric_grid']

from numpy import zeros, empty_like, empty, asarray
from itertools import combinations, product
from functools import partial

from .parallel import parmap

from cython cimport boundscheck, wraparound, profile

@profile(True)
@boundscheck(False)
@wraparound(False)
def embed(grid_indices, coordinates):
    vertices = empty((len(grid_indices), len(coordinates)), dtype="complex")
    for key, value in grid_indices.items():
        vertices[value] = [c[k] for c, k in zip(coordinates, key)]
    return vertices

@profile(True)
@boundscheck(False)
@wraparound(False) 
def grid_indices(shape, start=0):
    grid_indices = {}
    for index, index_list in enumerate(product(*[range(max_index) for max_index in shape])):
        grid_indices[index_list] = index + start
    return grid_indices

@profile(True)
@boundscheck(False)
def symmetric_grid(grid_indices):
    if not grid_indices:
        return asarray([], dtype="uint")
    def compute_dindices(dindices):
        new_dindices = []
        for i in range(len(dindices)):
            for j in crange:
                if not dindices[i][-1][j]:
                    dindices1 = asarray(dindices, dtype="int8").copy().tolist()
                    dindex = dindices1[i][-1]
                    dindex[j] = 1
                    dindices1[i].append(dindex)
                    new_dindices += compute_dindices(dindices1)
                    dindices2 = asarray(dindices, dtype="int8").copy().tolist()
                    dindex = dindices2[i][-1]
                    dindex[j] = -1
                    dindices2[i].append(dindex)
                    new_dindices += compute_dindices(dindices2)
        if new_dindices:
            return new_dindices
        else:
            return dindices
    num_axes = len(iter(grid_indices).next())
    crange = range(num_axes)
    dindices = asarray(compute_dindices([[[0] * num_axes]]), dtype="int8")
    dindices[:, -1] = zeros(num_axes, dtype="int8")
    simplices = []
    for index_list in grid_indices:
        index_list = asarray(index_list, "uint")
        if (index_list % 2).any():
            continue
        for dindex in dindices:
            valid_index = True
            simplex = []
            for indices in dindex + index_list:
                try:
                    simplex.append(grid_indices[tuple(indices)])
                except KeyError:
                    valid_index = False
                    break
            if valid_index:
                simplices.append(simplex)
    simplices = asarray(simplices, dtype="uint")
    return simplices

@profile(True)
@boundscheck(False)
def grid(grid_indices):
    if not grid_indices:
        return asarray([], dtype="uint")
    def compute_dindices(dindices):
        new_dindices = []
        for i in range(len(dindices)):
            for j in crange:
                if not dindices[i][-1][j]:
                    dindices1 = asarray(dindices, dtype="int8").copy().tolist()
                    dindex = dindices1[i][-1]
                    dindex[j] = 1
                    dindices1[i].append(dindex)
                    new_dindices += compute_dindices(dindices1)
                    #dindices2 = asarray(dindices, dtype="int8").copy().tolist()
                    #dindex = dindices2[i][-1]
                    #dindex[j] = -1
                    #dindices2[i].append(dindex)
                    #new_dindices += compute_dindices(dindices2)
        if new_dindices:
            return new_dindices
        else:
            return dindices
    num_axes = len(iter(grid_indices).next())
    crange = range(num_axes)
    dindices = asarray(compute_dindices([[[0] * num_axes]]), dtype="int8")
    dindices[:, -1] = zeros(num_axes, dtype="int8")
    simplices = []
    for index_list in grid_indices:
        index_list = asarray(index_list, "uint")
        #if (index_list % 2).any():
        #    continue
        for dindex in dindices:
            valid_index = True
            simplex = []
            for indices in dindex + index_list:
                try:
                    simplex.append(grid_indices[tuple(indices)])
                except KeyError:
                    valid_index = False
                    break
            if valid_index:
                simplices.append(simplex)
    simplices = asarray(simplices, dtype="uint")
    return simplices

def pbc_stitches(grid_indices, shape, pbc):
    stitches = {}
    crange = range(len(shape))
    for num_pbc in range(1, len(pbc) + 1):
        for pbc_combo in combinations(pbc, num_pbc):
            pbc_indices = []
            for index in crange:
                if index in pbc_combo:
                    pbc_indices.append([shape[index] - 1])
                else:
                    pbc_indices.append(range(shape[index]))
            for index_list in product(*pbc_indices):
                stitch_vertex = grid_indices[index_list]
                index_list = list(index_list)
                for pbc_index in pbc_combo:
                    index_list[pbc_index] = 0
                real_vertex = grid_indices[tuple(index_list)]
                stitches[stitch_vertex] = real_vertex
    return stitches

def _stitch(index, stitches):
    while index in stitches:
        index = stitches[index]
    return index

def stitch(simplex, dict stitches):
    return asarray([_stitch(s, stitches) for s in simplex], dtype="uint")