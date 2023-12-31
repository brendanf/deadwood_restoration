# DADA2 quality filtering and denoising for Sonja's spruce log metabarcoding data
# Brendan Furneaux
# Based on DADA2 analysis for GSSP from Jenni Hultman

library(magrittr)
library(targets)
library(tarchetypes)

#### DADA2 analysis based on Jenni Hultman's pipeline for GSSP

dada_plan <- list(
  #### dada2_meta ####
  # grouping structure here will lead to separate dada2 error models
  tar_target(
    dada2_meta,
    dplyr::group_by(sample_table, seqrun) %>%
      tar_group(),
    iteration = "group",
    deployment = "main"
  ),
  #### fastq_R1 ####
  # declare a file target for dependency tracking
  tar_file(
    fastq_R1,
    file.path(raw_path, dada2_meta$fastq_R1),
    pattern = map(dada2_meta),
    iteration = "list",
    deployment = "main"
  ),
  #### fastq_R2 ####
  # declare a file target for dependency tracking
  tar_file(
    fastq_R2,
    file.path(raw_path, dada2_meta$fastq_R2),
    pattern = map(dada2_meta),
    iteration = "list",
    deployment = "main"
  ),
  
  #### raw_read_counts ####
  tar_fst_tbl(
    raw_read_counts,
    tibble::tibble(
      fastq_file = fastq_R1,
      raw_nread = sequence_size(fastq_file)
    ),
    pattern = map(fastq_R1)
  ),
  
  #### trim ####
  # remove primers
  tar_file(
    trim,
    purrr::pmap(
      dplyr::transmute(
        dada2_meta,
        file_R1 = file.path(raw_path, fastq_R1),
        file_R2 = file.path(raw_path, fastq_R2),
        trim_R1 = trim_R1,
        trim_R2 = trim_R2
      ),
      cutadapt_paired_filter_trim,
      max_err = 0.2,
      min_overlap = 10,
      truncQ_R1 = 2,
      truncQ_R2 = c(10,2),
      max_n = 0,
      min_length = 100,
      primer_R1 = "GCATCGATGAAGAACGCAGC...GCATATCAATAAGCGGAGGA;optional",
      primer_R2 = "TCCTCCGCTTATTGATATGC...GCTGCGTTCTTCATCGATGC;optional",
      cut_R2 = 16,
      action = "retain",
      discard_untrimmed = TRUE,
      ncpu = local_cpus(),
    ) %>%
      unlist(),
    pattern = map(dada2_meta, fastq_R1, fastq_R2),
    iteration = "list"
  ),
  
  #### trim_read_counts ####
  tar_fst_tbl(
    trim_read_counts,
    tibble::tibble(
      trim_R1 = purrr::keep(trim, endsWith, "_R1_trim.fastq.gz"),
      trim_nread = sequence_size(trim_R1)
    ),
    pattern = map(trim)
  ),

  #### all_filtered ####
  tar_file(
    all_filtered,
    {
      file.create(c(dada2_meta$filt_R1, dada2_meta$filt_R2))
      dada2::filterAndTrim(
        fwd = purrr::keep(trim, endsWith, "_R1_trim.fastq.gz"),
        filt = dada2_meta$filt_R1,
        rev = purrr::keep(trim, endsWith, "_R2_trim.fastq.gz"),
        filt.rev = dada2_meta$filt_R2,
        #maxN = 0, # max 0 ambiguous bases
        maxEE = c(3, 5), # max expected errors (fwd, rev)
        #truncQ = 2, # truncate at first base with quality <= 2
        rm.phix = TRUE, #remove matches to phiX genome
        #minLen = 100, # remove reads < 100bp
        compress = TRUE, # write compressed files
        multithread = local_cpus(),
        verbose = TRUE
      )
      # return file names for samples where at least some reads passed
      c(dada2_meta$filt_R1, dada2_meta$filt_R2) %>%
        purrr::keep(file.exists)
    },
    pattern = map(trim, dada2_meta),
    iteration = "list"
  ),
  
  #### filt_read_counts ####
  tar_fst_tbl(
    filt_read_counts,
    tibble::tibble(
      filt_R1 = purrr::keep(all_filtered, endsWith, "_R1_filt.fastq.gz"),
      filt_nread = sequence_size(filt_R1)
    ),
    pattern = map(all_filtered)
  ),
  
  # inside the tar_map, every occurrence of read is replaced by "R1" or "R2"
  # the read name is also appended to all target names
  # so all of this gets done separately for forward and reverse reads.
  # pattern=map() means we are also keeping the different sequencing runs
  # separate
  tar_map(
    values = list(read = c("R1", "R2")),
    #### filtered_{read} ####
    tar_file(
      filtered,
      purrr::keep(all_filtered, endsWith, paste0(read, "_filt.fastq.gz")),
      pattern = map(all_filtered),
      iteration = "list",
      deployment = "main"
    ),
    
    #### derep_{read} ####
    tar_target(
      derep,
      dada2::derepFastq(filtered, verbose = TRUE) %>%
        set_names(sub("_R[12]_filt\\.fastq\\.gz", "", filtered)),
      pattern = map(filtered),
      iteration = "list"
    ),
    
    #### err_{read} ####
    tar_target(
      err,
      dada2::learnErrors(
        purrr::discard(filtered, grepl, pattern = "BLANK|NEG"),
        multithread = local_cpus(),
        verbose = TRUE
      ),
      pattern = map(filtered),
      iteration = "list"
    ),
    
    #### denoise_{read} ####
    tar_target(
      denoise,
      dada2::dada(derep, err = err, multithread = local_cpus(), verbose = TRUE),
      pattern = map(derep, err),
      iteration = "list"
    )
  ),
  #### merged ####
  # Merge paired reads and make a sequence table for each sequencing run
  tar_target(
    merged,
    dada2::mergePairs(denoise_R1, derep_R1, denoise_R2, derep_R2,
               minOverlap = 10, maxMismatch = 1, verbose=TRUE),
    pattern = map(denoise_R1, derep_R1, denoise_R2, derep_R2),
    iteration = "list"
  ),
  
  #### seqtable_raw ####
  # Make sequence table for each sequencing run
  # these may contain some sequences which are no-mismatch pairs, i.e. only
  # differ by length
  tar_target(
    seqtable_raw,
    dada2::makeSequenceTable(merged),
    pattern = map(merged),
    iteration = "list"
  ),
  
  #### denoise_read_counts ####
  tar_fst_tbl(
    denoise_read_counts,
    tibble::enframe(
      rowSums(seqtable_raw),
      name = "filt_key",
      value = "denoise_nread"
    ),
    pattern = map(seqtable_raw)
  ),
  
  #### seqtable_nochim ####
  # remove chimeric sequences
  tar_target(
    seqtable_nochim,
    dada2::removeBimeraDenovo(seqtable_raw, allowOneOff = TRUE, 
                       multithread = local_cpus(), verbose = TRUE),
    pattern = map(seqtable_raw),
    iteration = "list"
  ),
  
  #### nochim_read_counts ####
  tar_fst_tbl(
    nochim_read_counts,
    tibble::enframe(
      rowSums(seqtable_nochim),
      name = "filt_key",
      value = "nochim_nread"
    ),
    pattern = map(seqtable_nochim)
  ),
  
  #### seqtable_nospike ####
  # remove spike sequences
  tar_target(
    seqtable_nospike,
    {
      seqs <- colnames(seqtable_nochim)
      names(seqs) <- seq_along(seqs)
      spikes <- vsearch_usearch_global(
        seqs,
        "protaxFungi/addedmodel/amptk_synmock.udb",
        threshold = 0.9
      )
      seqtable_nochim[,-as.numeric(spikes$ASV)]
    },
    pattern = map(seqtable_nochim),
    iteration = "list"
  ),
  
  #### nospike_read_counts ####
  tar_fst_tbl(
    nospike_read_counts,
    tibble::enframe(
      rowSums(seqtable_nospike),
      name = "filt_key",
      value = "nospike_nread"
    ),
    pattern = map(seqtable_nospike)
  ),
  
  #### seqtable ####
  # Merge no-mismatch pairs
  tar_target(
    seqtable,
    collapseNoMismatch_vsearch(seqtable_nospike),
    pattern = map(seqtable_nospike),
    iteration = "list"
  ),
  
  #### asvtable_dup ####
  # combine all the remaining sequence tables into a master table
  # again, it's possible we have no-mismatch pairs between the different
  # sequencing runs.
  tar_target(
    asvtable_dup,
    if (length(seqtable) == 1) {
      seqtable[[1]]
    } else {
      dada2::mergeSequenceTables(tables = seqtable)
    },
    deployment = "main"
  ),
  
  #### asvtable_trim ####
  tar_target(
    asvtable_trim,
    trim_seqtable(
      asvtable_dup,
      primer = "GCATCGATGAAGAACGCAGC...GCATATCAATAAGCGGAGGA",
      max_err = 0.2,
      min_overlap = 10
    )
  ),
  
  #### asvtable_nodup ####
  # Merge no-mismatch pairs
  tar_target(
    asvtable,
    collapseNoMismatch_vsearch(asvtable_trim)
  ),
  
  #### write_asvtable ####
  tar_file(
    write_asvtable,
    file.path(asv_path, "asv_tab.rds") %T>%
      saveRDS(asvtable, .),
    deployment = "main"
  )
)
