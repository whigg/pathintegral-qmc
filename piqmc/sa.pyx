# encoding: utf-8
# cython: profile=False
# filename: sa.pyx
'''

File: sa.pyx
Author: Hadayat Seddiqi
Date: 10.13.14
Description: Do thermal annealing on a (sparse) Ising system.

'''

import numpy as np
cimport numpy as np
cimport cython
cimport openmp
from cython.parallel import prange, parallel
from libc.math cimport exp as cexp
from libc.stdlib cimport rand as crand
from libc.stdlib cimport RAND_MAX as RAND_MAX
# from libc.stdio cimport printf as cprintf


@cython.embedsignature(True)
def ClassicalIsingEnergy(spins, J):
    """
    Calculate energy for Ising graph @J in configuration @spins.
    Generally not needed for the annealing process but useful to
    have around at the end of simulations.
    """
    J = np.asarray(J.todense())
    d = np.diag(np.diag(J))
    np.fill_diagonal(J, 0.0)
    return -np.dot(spins, np.dot(J, spins)) - np.sum(np.dot(d,spins))

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.embedsignature(True)
@cython.cdivision(True)
cpdef Anneal(np.float_t[:] sched, 
             int mcsteps, 
             np.float_t[:] svec, 
             np.float_t[:, :, :] nbs, 
             rng):
    """
    Execute thermal annealing according to @annealingSchedule, an
    array of temperatures, which takes @mcSteps number of Monte Carlo
    steps per timestep.

    Starting configuration is given by @spinVector, which we update 
    and calculate energies using the Ising graph @isingJ. @rng is the 
    random number generator.

    Returns: None (spins are flipped in-place)
    """
    # Define some variables
    cdef int nspins = svec.size
    cdef int maxnb = nbs[0].shape[0]
    cdef int schedsize = sched.size
    cdef int itemp = 0
    cdef float temp = 0.0
    cdef int step = 0
    cdef int sidx = 0
    cdef int si = 0
    cdef int spinidx = 0
    cdef float jval = 0.0
    cdef float ediff = 0.0
    cdef np.ndarray[np.int_t, ndim=1] sidx_shuff = \
        rng.permutation(range(nspins))

    # Loop over temperatures
    for itemp in xrange(schedsize):
        # Get temperature
        temp = sched[itemp]
        # Do some number of Monte Carlo steps
        for step in xrange(mcsteps):
            # Loop over spins
            for sidx in sidx_shuff:
                # loop through the given spin's neighbors
                for si in xrange(maxnb):
                    # get the neighbor spin index
                    spinidx = int(nbs[sidx,si,0])
                    # get the coupling value to that neighbor
                    jval = nbs[sidx,si,1]
                    # self-connections are not quadratic
                    if spinidx == sidx:
                        ediff += -2.0*svec[sidx]*jval
                    # calculate the energy diff of flipping this spin
                    else:
                        ediff += -2.0*svec[sidx]*(jval*svec[spinidx])
                # Metropolis accept or reject
                if ediff >= 0.0:  # avoid overflow
                    svec[sidx] *= -1
                elif cexp(ediff/temp) > crand()/float(RAND_MAX):
                    svec[sidx] *= -1
                # Reset energy diff value
                ediff = 0.0
            sidx_shuff = rng.permutation(sidx_shuff)

@cython.boundscheck(False)
@cython.wraparound(False)
@cython.embedsignature(True)
@cython.cdivision(True)
cpdef Anneal_parallel(np.float_t[:] sched, 
                      int mcsteps, 
                      np.float_t[:] svec, 
                      np.float_t[:, :, :] nbs, 
                      int nthreads):
    """
    Execute thermal annealing according to @annealingSchedule, an
    array of temperatures, which takes @mcSteps number of Monte Carlo
    steps per timestep.

    Starting configuration is given by @spinVector, which we update 
    and calculate energies using the Ising graph @isingJ.

    This version attempts to do thread parallelization with Cython's
    built-in OpenMP directive "prange". The extra argument @nthreads
    specifies how many workers to split the spin updates amongst.

    Note that while the sequential version randomizes the order of
    spin updates, this version does not.

    Returns: None (spins are flipped in-place)
    """
    # Define some variables
    cdef int nspins = svec.size
    cdef int maxnb = nbs[0].shape[0]
    cdef int schedsize = sched.size
    cdef int itemp = 0
    cdef float temp = 0.0
    cdef int step = 0
    cdef int sidx = 0
    cdef int si = 0
    cdef int spinidx = 0
    cdef float jval = 0.0
    cdef np.ndarray[np.float_t, ndim=1] ediffs = np.zeros(nspins)

    with nogil, parallel(num_threads=nthreads):
        # Loop over temperatures
        for itemp in xrange(schedsize):
            # Get temperature
            temp = sched[itemp]
            # Do some number of Monte Carlo steps
            for step in xrange(mcsteps):
                # Loop over spins
                # print nthreads, openmp.omp_get_num_threads()
                for sidx in prange(nspins, schedule='static'):
                    ediffs[sidx] = 0.0  # reset
                    # loop through the neighbors
                    for si in xrange(maxnb):
                        # get the neighbor spin index
                        spinidx = int(nbs[sidx, si, 0])
                        # get the coupling value to that neighbor
                        jval = nbs[sidx, si, 1]
                        # self-connections are not quadratic
                        if spinidx == sidx:
                            ediffs[sidx] += -2.0*svec[sidx]*jval
                        else:
                            ediffs[sidx] += -2.0*svec[sidx]*(jval*svec[spinidx])
                    # Accept or reject
                    if ediffs[sidx] > 0.0:  # avoid overflow
                        svec[sidx] *= -1
                    elif cexp(ediffs[sidx]/temp) > crand()/float(RAND_MAX):
                        svec[sidx] *= -1


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.embedsignature(True)
cdef inline bint getbit(np.uint64_t s, int k):
    """
    Get the @k-th bit of @s.
    """
    return (s >> k) & 1


@cython.boundscheck(False)
@cython.wraparound(False)
@cython.embedsignature(True)
@cython.cdivision(True)
def Anneal_multispin(np.float_t[:] sched, 
                     int mcsteps, 
                     np.float_t[:, :] svec_mat, 
                     np.float_t[:, :, :] nbs, 
                     rng):
    """
    Execute thermal annealing according to @sched, an array of temperatures, 
    which takes @mcsteps number of Monte Carlo steps per timestep.

    This is a multispin encoding version, where we encode many parallel
    simulation states in the bits of some integers. Namely, we start with
    @svec_mat which has 32 or 64 rows denoting individual start states.
    We update and calculate energies using the neighbors datastructure @nbs,
    which encodes information from the problem's Ising graph. @rng is the 
    random number generator.

    Returns: None (spins are flipped in-place)
    """
    # Define some variables
    cdef int nspins = svec_mat.shape[1]
    cdef int maxnb = nbs[0].shape[0]
    cdef int schedsize = sched.size
    cdef int itemp = 0
    cdef float temp = 0.0
    cdef int step = 0
    cdef int sidx = 0
    cdef int si = 0
    cdef int spinidx = 0
    cdef float jval = 0.0
    cdef int k = 0
    cdef np.uint64_t flipmask = 0
    cdef np.ndarray[np.uint64_t, ndim=1] svec = np.zeros(nspins, dtype=np.uint64)
    cdef np.ndarray[np.int8_t, ndim=1] sign = np.zeros(64, dtype=np.int8)
    cdef np.ndarray[np.int64_t, ndim=1] spinstate = np.zeros(64, dtype=np.int64) ###
    cdef np.ndarray[np.float_t, ndim=1] ediffs = np.zeros(64)
    cdef np.ndarray[np.float_t, ndim=1] rands = rng.rand(64)
    cdef np.ndarray[np.int_t, ndim=1] sidx_shuff = \
        rng.permutation(range(nspins))
    # encode @svec_mat into the bits of svec elements
    for si in xrange(svec_mat.shape[1]):
        for k in xrange(svec_mat.shape[0]):
            # shift left to make room
            svec[si] = svec[si] << 1
            # set bit if we want to
            if svec_mat[k,si]:
                svec[si] = svec[si] ^ 0x01
    # Loop over temperatures
    for itemp in xrange(schedsize):
        # Get temperature
        temp = sched[itemp]
        # Do some number of Monte Carlo steps
        for step in xrange(mcsteps):
            # Loop over spins
            for sidx in sidx_shuff:
                # loop through the given spin's neighbors
                for si in xrange(maxnb):
                    # get the neighbor spin index
                    spinidx = int(nbs[sidx,si,0])
                    # get the coupling value to that neighbor
                    jval = nbs[sidx,si,1]
                    # self-connections are not quadratic
                    if spinidx == sidx:
                        # loop over bits
                        for k in xrange(64):
                            # zero maps to one, one maps to negative 1
                            if not getbit(svec[sidx], 63 - k):
                                ediffs[k] -= 2.0*jval
                            else:
                                ediffs[k] += 2.0*jval
                    # quadratic part
                    else:
                        # do the XOR to see bit disagreements
                        flipmask = svec[sidx] ^ svec[spinidx]
                        # loop over bits
                        for k in xrange(64):
                            # zero maps to one, one maps to negative 1
                            if not getbit(flipmask, 63 - k):
                                ediffs[k] -= 2.0*jval
                            else:
                                ediffs[k] += 2.0*jval
                # prepare to flip those whose Boltzmann weights are 
                # larger than random samples
                sign = np.asarray(np.exp(ediffs/temp) > rands, dtype=np.int8)
                # set a one and shift left
                flipmask = 1 if sign[0] else 0
                # go through all except the first
                for k in xrange(1, 64):
                    # shift last value left to make room
                    flipmask = flipmask << 1
                    # if we want to flip, set a one
                    if sign[k]:
                        flipmask ^= 0x01
                # do the flip
                svec[sidx] ^= flipmask
                # reset energy differences
                ediffs.fill(0.0)
                # new random numbers
                rands = rng.rand(64)
            # reshuffle update order
            sidx_shuff = rng.permutation(sidx_shuff)
    # unpack and return
    for sidx in xrange(svec.size+1):
        state = bin(svec[sidx])[2:].rjust(64,'0')
        for k in xrange(len(state)):
            svec_mat[k,sidx] = float(state[k])
