# COMMENTS FROM AARON:
# We decline to use nearest neighbors here, because there's no opportunity to build a single index.
# Moreover, the data are so reduced in both dimensions that the algorithmic complexity is likely
# offset by the reduction in overhead when just computing the correlations directly.
# One could possibly improve vectorization by grouping together test cells with the same
# combination of topLabels, but it adds a lot of complexity and additional overhead.

#' @importFrom BiocParallel bplapply bpmapply SerialParam
.fine_tune_de <- function(exprs, scores, references, quantile, tune.thresh, de.info, BPPARAM=SerialParam()) {
    # Checking that all names are in sync.
    stopifnot(identical(names(references), colnames(scores)))
    stopifnot(identical(names(references), names(de.info)))
    for (markers in de.info) {
        stopifnot(identical(names(markers), names(de.info)))
    }

    # Scanning across all references and subsetting to the common genes.
    # This should reduce the amount of data that gets distributed,
    # as well as the number of cache misses.
    universe <- unique(unlist(lapply(de.info, unlist, use.names=FALSE), use.names=FALSE))
    references <- lapply(references, function(x) x[universe,,drop=FALSE])
    exprs <- exprs[universe,,drop=FALSE]

    # Converting character vectors into integer indices.
    de.info <- lapply(de.info, function(markers) {
        lapply(markers, function(x) match(x, universe) - 1L)
    })

    # We assume that classifySingleR() has already set up the backend.
    M <- .prep_for_parallel(exprs, BPPARAM)
    S <- .cofragment_matrix(M, t(scores))

    bp.out <- bpmapply(Exprs=M, scores=S, FUN=fine_tune_label_de, 
        MoreArgs=list(References=references, quantile=quantile, tune_thresh=tune.thresh, marker_genes=de.info), 
        BPPARAM=BPPARAM, SIMPLIFY=FALSE, USE.NAMES=FALSE)

    do.call(mapply, c(bp.out, list(FUN=c, SIMPLIFY=FALSE, USE.NAMES=FALSE)))
}

#' @importFrom BiocParallel bpmapply SerialParam
.fine_tune_sd <- function(exprs, scores, references, quantile, tune.thresh, median.mat, sd.thresh, BPPARAM=SerialParam()) {
    stopifnot(identical(names(references), colnames(scores)))

    M <- .prep_for_parallel(exprs, BPPARAM)
    S <- .prep_for_parallel(t(scores), BPPARAM)
    bp.out <- bpmapply(Exprs=M, scores=S, FUN=fine_tune_label_sd, 
        MoreArgs=list(References=references, quantile=quantile, tune_thresh=tune.thresh, 
            median_mat=t(median.mat), sd_thresh=sd.thresh),
        BPPARAM=BPPARAM, SIMPLIFY=FALSE, USE.NAMES=FALSE)

    do.call(mapply, c(bp.out, list(FUN=c, SIMPLIFY=FALSE, USE.NAMES=FALSE)))
}

#' @importFrom BiocParallel bpnworkers
#' @importFrom DelayedArray colGrid getAutoBlockLength
#' @importFrom BiocGenerics dims
.prep_for_parallel <- function(mat, BPPARAM, use.grid=FALSE) {
    is.int <- !is.double(as.matrix(mat[0,0]))
    n_cores <- bpnworkers(BPPARAM)

    if (n_cores==1L && !use.grid) {
        # Can't be bothered to template it twice at the C++ level,
        # as we'd have to have both int/numeric versions for the test and reference.
        if (is.int) {
            mat <- mat + 0
        }
        return(list(mat))
    }

    # Split the matrix *before* parallelization,
    # otherwise the full matrix gets serialized to all workers.
    if (!use.grid) {
        boundaries <- as.integer(seq(from = 1L, to = ncol(mat)+1L, length.out = n_cores + 1L)) 
    } else {
        possible.block <- ceiling(ncol(mat) / n_cores) * nrow(mat)
        allowed.block <- getAutoBlockLength(if (is.int) "integer" else "double")
        grid <- colGrid(mat, block.length=min(possible.block, allowed.block))
        boundaries <- c(1L, cumsum(dims(grid)[,2])+1L)
    }

    out <- vector("list", length(boundaries)-1L)
    for (i in seq_along(out)) {
        cur_start <- boundaries[i]
        cur_end <- boundaries[i+1]
        curmat <- mat[,(cur_start - 1L) + seq_len(cur_end - cur_start),drop=FALSE]
        if (is.int) {
            curmat <- curmat + 0
        }
        out[[i]] <- curmat
    }

    out
}

.cofragment_matrix <- function(prepped, mat) 
# Not breaking up `mat` in `.prep_for_parallel` as `use.grid=TRUE` means that
# the choice of parallelization scheme is not purely driven by the number of
# columns in `mat`. Also, `.prep_for_parallel` coerces to numeric, and
# `mat` may not be.
{
    output <- vector("list", length(prepped)) 
    counter <- 0L
    for (i in seq_along(output)) {
        N <- ncol(prepped[[i]])
        output[[i]] <- mat[,counter + seq_len(N),drop=FALSE]
        counter <- counter + N
    }
    output
}
