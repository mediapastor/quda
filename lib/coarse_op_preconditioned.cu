#include <gauge_field.h>
#include <blas_cublas.h>
#include <blas_quda.h>
#include <tune_quda.h>

#include <jitify_helper.cuh>
#include <kernels/coarse_op_preconditioned.cuh>

namespace quda {

#ifdef GPU_MULTIGRID

  template <typename Float, int n, typename Arg>
  class CalculateYhat : public TunableVectorYZ {

  protected:
    Arg &arg;
    const LatticeField &meta;

    long long flops() const { return 2l * arg.coarseVolumeCB * 8 * n * n * (8*n-2); } // 8 from dir, 8 from complexity,
    long long bytes() const { return 2l * (arg.Xinv.Bytes() + 8*arg.Y.Bytes() + 8*arg.Yhat.Bytes()) * n; }

    unsigned int minThreads() const { return arg.coarseVolumeCB; }

    bool tuneGridDim() const { return false; } // don't tune the grid dimension

  public:
    CalculateYhat(Arg &arg, const LatticeField &meta) : TunableVectorYZ(2*n,4*n), arg(arg), meta(meta)
    {
      if (meta.Location() == QUDA_CUDA_FIELD_LOCATION) {
#ifdef JITIFY
        create_jitify_program("kernels/coarse_op_preconditioned.cuh");
#endif
        strcpy(aux, "GPU-");
        strcat(aux, compile_type_str);
        strcat(aux,",");
      } else {
        strcpy(aux, "CPU,");
      }
      strcat(aux,comm_dim_partitioned_string());
    }
    virtual ~CalculateYhat() { }

    void apply(const cudaStream_t &stream) {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      if (meta.Location() == QUDA_CPU_FIELD_LOCATION) {
	CalculateYhatCPU<Float,n,Arg>(arg);
      } else {
#ifdef JITIFY
        using namespace jitify::reflection;
        jitify_error = program->kernel("quda::CalculateYhatGPU")
          .instantiate(Type<Float>(),n,Type<Arg>())
          .configure(tp.grid,tp.block,tp.shared_bytes,stream).launch(arg);
#else
	CalculateYhatGPU<Float,n,Arg> <<<tp.grid,tp.block,tp.shared_bytes>>>(arg);
#endif
      }
    }

    // no locality in this kernel so no point in shared-memory tuning
    bool advanceSharedBytes(TuneParam &param) const { return false; }

    bool advanceTuneParam(TuneParam &param) const {
      if (meta.Location() == QUDA_CUDA_FIELD_LOCATION && meta.MemType() == QUDA_MEMORY_DEVICE) return Tunable::advanceTuneParam(param);
      else return false;
    }

    TuneKey tuneKey() const {
      char Aux[TuneKey::aux_n];
      strcpy(Aux,aux);
      if (meta.Location() == QUDA_CUDA_FIELD_LOCATION) {
        strcat(Aux, meta.MemType() == QUDA_MEMORY_MAPPED ? ",GPU-mapped" : ",GPU-device");
      } else if (meta.Location() == QUDA_CPU_FIELD_LOCATION) {
        strcat(Aux, ",CPU");
        strcat(Aux, getOmpThreadStr());
      }
      return TuneKey(meta.VolString(), typeid(*this).name(), Aux);
    }
  };

  /**
     @brief Calculate the preconditioned coarse-link field and the clover inverse.

     @param Yhat[out] Preconditioned coarse link field
     @param Xinv[out] Coarse clover inverse field
     @param Y[out] Coarse link field
     @param X[out] Coarse clover field
   */
  template<typename storeFloat, typename Float, int N, QudaGaugeFieldOrder gOrder>
  void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X)
  {
    // invert the clover matrix field
    const int n = X.Ncolor();
    if (X.Location() == QUDA_CUDA_FIELD_LOCATION && X.Order() == QUDA_FLOAT2_GAUGE_ORDER) {
      GaugeFieldParam param(X);
      // need to copy into AoS format for CUBLAS
      param.order = QUDA_MILC_GAUGE_ORDER;
      param.setPrecision( X.Precision() < QUDA_SINGLE_PRECISION ? QUDA_SINGLE_PRECISION : X.Precision() );
      cudaGaugeField X_(param);
      cudaGaugeField Xinv_(param);
      X_.copy(X);
      blas::flops += cublas::BatchInvertMatrix((void*)Xinv_.Gauge_p(), (void*)X_.Gauge_p(), n, X_.Volume(), X_.Precision(), X.Location());

      if (Xinv.Precision() < QUDA_SINGLE_PRECISION) Xinv.Scale( Xinv_.abs_max() );

      Xinv.copy(Xinv_);

    } else if (X.Location() == QUDA_CPU_FIELD_LOCATION && X.Order() == QUDA_QDP_GAUGE_ORDER) {
      const cpuGaugeField *X_h = static_cast<const cpuGaugeField*>(&X);
      cpuGaugeField *Xinv_h = static_cast<cpuGaugeField*>(&Xinv);
      blas::flops += cublas::BatchInvertMatrix(((void**)Xinv_h->Gauge_p())[0], ((void**)X_h->Gauge_p())[0], n, X_h->Volume(), X.Precision(), QUDA_CPU_FIELD_LOCATION);
    } else {
      errorQuda("Unsupported location=%d and order=%d", X.Location(), X.Order());
    }

    // now exchange Y halos of both forwards and backwards links for multi-process dslash
    const_cast<GaugeField&>(Y).exchangeGhost(QUDA_LINK_BIDIRECTIONAL);

    // compute the preconditioned links
    // Yhat_back(x-\mu) = Y_back(x-\mu) * Xinv^dagger(x) (positive projector)
    // Yhat_fwd(x) = Xinv(x) * Y_fwd(x)                  (negative projector)
    {
      int xc_size[5];
      for (int i=0; i<4; i++) xc_size[i] = X.X()[i];
      xc_size[4] = 1;

      // use spin-ignorant accessor to make multiplication simpler
      typedef typename gauge::FieldOrder<Float,N,1,gOrder,true,storeFloat> gCoarse;
      typedef typename gauge::FieldOrder<Float,N,1,gOrder,true,storeFloat> gPreconditionedCoarse;
      gCoarse yAccessor(const_cast<GaugeField&>(Y));
      gPreconditionedCoarse yHatAccessor(const_cast<GaugeField&>(Yhat));
      gCoarse xInvAccessor(const_cast<GaugeField&>(Xinv));
      if (getVerbosity() >= QUDA_VERBOSE) printfQuda("Xinv = %e\n", Xinv.norm2(0));

      int comm_dim[4];
      for (int i=0; i<4; i++) comm_dim[i] = comm_dim_partitioned(i);
      typedef CalculateYhatArg<gPreconditionedCoarse,gCoarse,N> yHatArg;
      yHatArg arg(yHatAccessor, yAccessor, xInvAccessor, xc_size, comm_dim, 1);

      if (Yhat.Precision() == QUDA_HALF_PRECISION) {
	double max = 3.0 * Y.abs_max() * Xinv.abs_max();
	Yhat.Scale(max);
	arg.Yhat.resetScale(max);
      }

      CalculateYhat<Float, N, yHatArg> yHat(arg, Y);
      yHat.apply(0);

      if (getVerbosity() >= QUDA_VERBOSE)
	for (int d=0; d<8; d++) printfQuda("Yhat[%d] = %e (%e %e = %e x %e)\n", d, Yhat.norm2(d),
					   Yhat.abs_max(d), Y.abs_max(d) * Xinv.abs_max(0),
					   Y.abs_max(d), Xinv.abs_max(0));

    }

    // fill back in the bulk of Yhat so that the backward link is updated on the previous node
    // need to put this in the bulk of the previous node - but only send backwards the backwards
    // links to and not overwrite the forwards bulk
    Yhat.injectGhost(QUDA_LINK_BACKWARDS);

    // exchange forwards links for multi-process dslash dagger
    // need to put this in the ghost zone of the next node - but only send forwards the forwards
    // links and not overwrite the backwards ghost
    Yhat.exchangeGhost(QUDA_LINK_FORWARDS);
  }

  template <typename storeFloat, typename Float, int N>
  void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X)
  {
    if (Y.Location() == QUDA_CPU_FIELD_LOCATION) {
      constexpr QudaGaugeFieldOrder gOrder = QUDA_QDP_GAUGE_ORDER;
      if (Y.FieldOrder() != gOrder) errorQuda("Unsupported field order %d\n", Y.FieldOrder());
      calculateYhat<storeFloat,Float,N,gOrder>(Yhat, Xinv, Y, X);
    } else {
      constexpr QudaGaugeFieldOrder gOrder = QUDA_FLOAT2_GAUGE_ORDER;
      if (Y.FieldOrder() != gOrder) errorQuda("Unsupported field order %d\n", Y.FieldOrder());
      calculateYhat<storeFloat,Float,N,gOrder>(Yhat, Xinv, Y, X);
    }
  }

  // template on the number of coarse degrees of freedom
  template <typename storeFloat, typename Float>
  void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X) {
    switch (Y.Ncolor()) {
    case  2: calculateYhat<storeFloat,Float, 2>(Yhat, Xinv, Y, X); break;
    case  4: calculateYhat<storeFloat,Float, 4>(Yhat, Xinv, Y, X); break;
    case  8: calculateYhat<storeFloat,Float, 8>(Yhat, Xinv, Y, X); break;
    case 12: calculateYhat<storeFloat,Float,12>(Yhat, Xinv, Y, X); break;
    case 16: calculateYhat<storeFloat,Float,16>(Yhat, Xinv, Y, X); break;
    case 20: calculateYhat<storeFloat,Float,20>(Yhat, Xinv, Y, X); break;
    case 24: calculateYhat<storeFloat,Float,24>(Yhat, Xinv, Y, X); break;
    case 32: calculateYhat<storeFloat,Float,32>(Yhat, Xinv, Y, X); break;
    case 48: calculateYhat<storeFloat,Float,48>(Yhat, Xinv, Y, X); break;
    case 64: calculateYhat<storeFloat,Float,64>(Yhat, Xinv, Y, X); break;
    default: errorQuda("Unsupported number of coarse dof %d\n", Y.Ncolor()); break;
    }
  }

#endif

  //Does the heavy lifting of creating the coarse color matrices Y
  void calculateYhat(GaugeField &Yhat, GaugeField &Xinv, const GaugeField &Y, const GaugeField &X) {

#ifdef GPU_MULTIGRID
    QudaPrecision precision = checkPrecision(Xinv, Y, X);
    if (getVerbosity() >= QUDA_SUMMARIZE) printfQuda("Computing Yhat field......\n");

    if (precision == QUDA_DOUBLE_PRECISION) {
#ifdef GPU_MULTIGRID_DOUBLE
      if (Yhat.Precision() != QUDA_DOUBLE_PRECISION) errorQuda("Unsupported precision %d\n", Yhat.Precision());
      calculateYhat<double,double>(Yhat, Xinv, Y, X);
#else
      errorQuda("Double precision multigrid has not been enabled");
#endif
    } else if (precision == QUDA_SINGLE_PRECISION) {
      if (Yhat.Precision() == QUDA_SINGLE_PRECISION) {
	calculateYhat<float,float>(Yhat, Xinv, Y, X);
      } else {
	errorQuda("Unsupported precision %d\n", precision);
      }
    } else if (precision == QUDA_HALF_PRECISION) {
      if (Yhat.Precision() == QUDA_HALF_PRECISION) {
	calculateYhat<short,float>(Yhat, Xinv, Y, X);
      } else {
	errorQuda("Unsupported precision %d\n", precision);
      }
    } else {
      errorQuda("Unsupported precision %d\n", precision);
    }

    if (getVerbosity() >= QUDA_SUMMARIZE) printfQuda("....done computing Yhat field\n");
#else
    errorQuda("Multigrid has not been enabled");
#endif
  }

} //namespace quda

