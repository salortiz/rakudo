# this is actually part of the Array class

    constant dim2type :=
      nqp::list(Mu,Shaped1Array[Mu],Shaped2Array[Mu],Shaped3Array[Mu]);
    constant ArrayN := ShapedArray[Mu];

    sub set-shape(\arr, \shape) {
        nqp::stmts(
          (my $shape := nqp::if(
            Metamodel::EnumHOW.ACCEPTS(shape.HOW),
            shape.^elems,
            nqp::if(
              nqp::istype(shape,List),
              shape,
              shape.list
            )
          )),
          nqp::if(
            (my int $dimensions = $shape.elems),  # reifies
            nqp::stmts(
              nqp::bindattr(arr.^mixin(
                nqp::ifnull(nqp::atpos(dim2type,$dimensions),ArrayN)),
              List,'$!reified',
              Rakudo::Internals.SHAPED-ARRAY-STORAGE($shape,nqp::knowhow,Mu)),
              arr.^set_name('Array'),
              nqp::bindattr(arr, arr.WHAT, '$!shape', $shape),
              arr
            ),
            Failure.new(X::NotEnoughDimensions(
              operation         => 'create',
              got-dimensions    => 0,
              needed-dimensions => '',
            ))
          )
        )
    }

# vim: ft=perl6 expandtab sw=4
